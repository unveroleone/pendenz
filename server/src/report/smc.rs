// The Mac's System Management Controller, read through IOKit without root: the whole system's
// power (`PSTR`) and the CPU's temperature sensors. Only on macOS; elsewhere `Smc::open` fails.
#[cfg(target_os = "macos")]
pub use mac::Smc;

#[cfg(not(target_os = "macos"))]
pub struct Smc;

#[cfg(not(target_os = "macos"))]
impl Smc {
    pub fn open() -> anyhow::Result<Self> {
        anyhow::bail!("Energy is measured on macOS only.")
    }
    pub fn power(&self) -> Option<f64> {
        None
    }
    pub fn cpu_temperature(&self) -> Option<f64> {
        None
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::ffi::{c_char, c_void};

    type KernReturn = i32;
    type MachPort = u32;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceMatching(name: *const c_char) -> *mut c_void;
        // Takes over the matching dictionary.
        fn IOServiceGetMatchingService(main_port: MachPort, matching: *mut c_void) -> u32;
        fn IOServiceOpen(service: u32, task: MachPort, kind: u32, connect: *mut u32) -> KernReturn;
        fn IOServiceClose(connect: u32) -> KernReturn;
        fn IOObjectRelease(object: u32) -> KernReturn;
        fn IOConnectCallStructMethod(
            connect: u32,
            selector: u32,
            input: *const c_void,
            input_size: usize,
            output: *mut c_void,
            output_size: *mut usize,
        ) -> KernReturn;
    }
    unsafe extern "C" {
        static mach_task_self_: MachPort;
    }

    // The structure AppleSMC's user client takes and gives back, laid out as in C.
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct Version {
        major: u8,
        minor: u8,
        build: u8,
        reserved: u8,
        release: u16,
    }
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct PowerLimits {
        version: u16,
        length: u16,
        cpu: u32,
        gpu: u32,
        memory: u32,
    }
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct KeyInfo {
        size: u32,
        kind: u32,
        attributes: u8,
    }
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct KeyData {
        key: u32,
        version: Version,
        limits: PowerLimits,
        info: KeyInfo,
        result: u8,
        status: u8,
        command: u8,
        index: u32,
        bytes: [u8; 32],
    }
    const _: () = {
        assert!(std::mem::size_of::<KeyData>() == 80);
        assert!(std::mem::offset_of!(KeyData, limits) == 12);
        assert!(std::mem::offset_of!(KeyData, info) == 28);
        assert!(std::mem::offset_of!(KeyData, result) == 40);
        assert!(std::mem::offset_of!(KeyData, command) == 42);
        assert!(std::mem::offset_of!(KeyData, index) == 44);
        assert!(std::mem::offset_of!(KeyData, bytes) == 48);
    };

    // The user client's one method, and the commands it takes.
    const CALL: u32 = 2;
    const READ: u8 = 5;
    const KEY_AT_INDEX: u8 = 8;
    const KEY_INFO: u8 = 9;

    const fn code(name: &[u8; 4]) -> u32 {
        u32::from_be_bytes(*name)
    }
    const FLOAT: u32 = code(b"flt ");
    const COUNT: u32 = code(b"#KEY");
    const POWER: u32 = code(b"PSTR");

    // A reading outside this range is a sensor that is off or not fitted.
    const PLAUSIBLE_CELSIUS: std::ops::RangeInclusive<f64> = 10.0..=130.0;

    pub struct Smc {
        connection: u32,
        // The CPU's temperature sensors (`Tp..`) that hold a float.
        cpu_sensors: Vec<u32>,
    }

    impl Smc {
        pub fn open() -> anyhow::Result<Self> {
            // SAFETY: plain IOKit calls with a C string and out pointers that live through them.
            let connection = unsafe {
                let matching = IOServiceMatching(c"AppleSMC".as_ptr());
                anyhow::ensure!(!matching.is_null(), "IOKit has no AppleSMC");
                let service = IOServiceGetMatchingService(0, matching);
                anyhow::ensure!(service != 0, "This Mac has no AppleSMC service");
                let mut connection = 0;
                let result = IOServiceOpen(service, mach_task_self_, 0, &mut connection);
                IOObjectRelease(service);
                anyhow::ensure!(result == 0, "AppleSMC refused the connection ({result})");
                connection
            };
            let mut smc = Smc {
                connection,
                cpu_sensors: Vec::new(),
            };
            let count = smc
                .read(COUNT)
                .filter(|(_, bytes)| bytes.len() == 4)
                .map(|(_, bytes)| u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                .unwrap_or(0);
            for index in 0..count.min(10_000) {
                let Some(key) = smc.key_at(index) else {
                    continue;
                };
                if key >> 16 == u32::from(u16::from_be_bytes(*b"Tp"))
                    && smc.read(key).is_some_and(|(kind, _)| kind == FLOAT)
                {
                    smc.cpu_sensors.push(key);
                }
            }
            Ok(smc)
        }

        fn call(&self, input: &KeyData) -> Option<KeyData> {
            let mut output = KeyData::default();
            let mut size = std::mem::size_of::<KeyData>();
            // SAFETY: both buffers are KeyData, laid out as the user client expects (checked
            // above), and live through the call.
            let result = unsafe {
                IOConnectCallStructMethod(
                    self.connection,
                    CALL,
                    (input as *const KeyData).cast(),
                    std::mem::size_of::<KeyData>(),
                    (&mut output as *mut KeyData).cast(),
                    &mut size,
                )
            };
            (result == 0 && size == std::mem::size_of::<KeyData>() && output.result == 0)
                .then_some(output)
        }

        fn key_at(&self, index: u32) -> Option<u32> {
            self.call(&KeyData {
                command: KEY_AT_INDEX,
                index,
                ..KeyData::default()
            })
            .map(|o| o.key)
        }

        // A key's type and its bytes.
        fn read(&self, key: u32) -> Option<(u32, Vec<u8>)> {
            let info = self.call(&KeyData {
                key,
                command: KEY_INFO,
                ..KeyData::default()
            })?;
            let size = info.info.size as usize;
            if size == 0 || size > 32 {
                return None;
            }
            let data = self.call(&KeyData {
                key,
                info: info.info,
                command: READ,
                ..KeyData::default()
            })?;
            Some((info.info.kind, data.bytes[..size].to_vec()))
        }

        fn float(&self, key: u32) -> Option<f64> {
            match self.read(key)? {
                (FLOAT, bytes) if bytes.len() == 4 => {
                    let value = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                    value.is_finite().then_some(f64::from(value))
                }
                _ => None,
            }
        }

        // The whole system's power in watts, as the SMC measures it.
        pub fn power(&self) -> Option<f64> {
            self.float(POWER).filter(|w| (0.0..=2000.0).contains(w))
        }

        // The mean of the CPU's sensors that give a plausible reading, in degrees Celsius.
        pub fn cpu_temperature(&self) -> Option<f64> {
            let readings: Vec<f64> = self
                .cpu_sensors
                .iter()
                .filter_map(|&key| self.float(key))
                .filter(|c| PLAUSIBLE_CELSIUS.contains(c))
                .collect();
            (!readings.is_empty()).then(|| readings.iter().sum::<f64>() / readings.len() as f64)
        }
    }

    impl Drop for Smc {
        fn drop(&mut self) {
            // SAFETY: the connection was opened by `open` and is closed once.
            unsafe {
                IOServiceClose(self.connection);
            }
        }
    }
}
