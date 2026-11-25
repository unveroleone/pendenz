use crate::{
    AppState,
    auth::{Identity, hash, sha256_hex},
    error::{ApiError, Result},
    items::{self, About, Payload, Written, item_id, next_seq, record, visible_item},
    model::{FileRef, Item},
    notes::{Note, visible_note},
    settings::{self, FILE_CEILING_MB, MB},
};
use axum::{
    Extension, Json,
    body::Body,
    extract::{OriginalUri, Path, Request, State},
    http::{HeaderMap, HeaderValue, Method, StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use percent_encoding::{NON_ALPHANUMERIC, percent_decode_str, utf8_percent_encode};
use serde_json::{Map, Value, json};
use sqlx::SqliteConnection;

// The most files an item or a note holds.
const PER_HOLDER: usize = 40;
// A small file can announce a huge picture, and whoever shows it needs the memory for it. A
// picture above this is kept as a file without a size.
pub(crate) const PIXEL_LIMIT: u64 = 40_000_000;
const CEILING: usize = (FILE_CEILING_MB as u64 * MB) as usize;
// How many uploads may be read into memory at once. Each can hold up to the ceiling.
pub const UPLOADS_AT_ONCE: usize = 2;
// How many downloads may hold a file in memory at once, until it is sent or the client leaves.
pub const DOWNLOADS_AT_ONCE: usize = 4;
// How much of a file is handed to the connection at a time.
const CHUNK: usize = 256 * 1024;

// A file that was read and hashed, before the writer lock is taken.
pub(crate) struct Upload {
    name: String,
    mime: String,
    upload_id: Option<String>,
    pub sha256: String,
    size: Option<(i64, i64)>,
    data: Vec<u8>,
}

impl Upload {
    // An image sent to the old image route, already checked and measured there.
    pub(crate) fn picture(
        name: &str,
        mime: &str,
        sha256: String,
        size: (i64, i64),
        data: Vec<u8>,
    ) -> Self {
        Self {
            name: name.into(),
            mime: mime.into(),
            upload_id: None,
            sha256,
            size: Some(size),
            data,
        }
    }
}

// The width and height of a picture the apps can draw, read from its first bytes whatever the
// sender calls it. Any other file, or a picture too large to draw safely, has none.
fn picture_size(data: &[u8]) -> Option<(i64, i64)> {
    use imagesize::ImageType;
    match imagesize::image_type(data).ok()? {
        ImageType::Jpeg
        | ImageType::Png
        | ImageType::Gif
        | ImageType::Webp
        | ImageType::Heif(_) => {}
        _ => return None,
    }
    let size = imagesize::blob_size(data).ok()?;
    let (width, height) = (size.width as u64, size.height as u64);
    (width > 0 && height > 0 && width.saturating_mul(height) <= PIXEL_LIMIT)
        .then_some((width as i64, height as i64))
}

fn too_large(limit_mb: i64) -> ApiError {
    ApiError(
        StatusCode::PAYLOAD_TOO_LARGE,
        format!("A file can be at most {limit_mb} MB."),
    )
}

// The file's name, sent percent-encoded because a header carries ASCII only. Used as a name and
// never as a path, but a name that looks like one is refused anyway.
fn file_name(headers: &HeaderMap) -> Result<String> {
    let shape = || {
        ApiError::bad(
            "Send the file's name, percent-encoded UTF-8, in the Pendenz-File-Name header.",
        )
    };
    let raw = headers
        .get("pendenz-file-name")
        .ok_or_else(shape)?
        .to_str()
        .map_err(|_| shape())?;
    let name = percent_decode_str(raw)
        .decode_utf8()
        .map_err(|_| shape())?
        .into_owned();
    if name.is_empty()
        || name.len() > 255
        || name == "."
        || name == ".."
        || name
            .chars()
            .any(|c| c == '/' || c == '\\' || c.is_control())
    {
        return Err(ApiError::bad(
            "A file name has 1 to 255 bytes and no slash, backslash or control character.",
        ));
    }
    Ok(name)
}

// The type as the sender names it, without parameters. Anything that is not a plain
// type/subtype is stored as a file of unknown type.
fn mime(headers: &HeaderMap) -> String {
    let token = |part: &str| {
        !part.is_empty()
            && part
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"!#$&-^_.+".contains(&c))
    };
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| {
            value
                .split_once('/')
                .is_some_and(|(kind, sub)| token(kind) && token(sub))
        })
        .unwrap_or_else(|| "application/octet-stream".into())
}

fn upload_id(headers: &HeaderMap) -> Result<Option<String>> {
    let Some(value) = headers.get("pendenz-upload-id") else {
        return Ok(None);
    };
    match value.to_str() {
        Ok(id)
            if (1..=64).contains(&id.len())
                && id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') =>
        {
            Ok(Some(id.into()))
        }
        _ => Err(ApiError::bad(
            "Pendenz-Upload-Id has 1 to 64 letters, digits or hyphens.",
        )),
    }
}

// `POST /api/items/<id>/files` and `POST /api/notes/<id>/files`, told apart by the path when
// the writer files the upload. The body is the file itself, not JSON: base64 would make it a
// third larger and hold it twice. It is read and hashed before the writer lock, which is never
// held while bytes still arrive, and then handed to the same writer as every other change.
pub async fn upload(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
    body: Body,
) -> Result<Json<Value>> {
    identity.require("write")?;
    item_id(&id)?;
    let key = items::idempotency_key(&headers)?.to_owned();
    let name = file_name(&headers)?;
    let mime = mime(&headers);
    let upload_id = upload_id(&headers)?;
    // The current limit only names the size in the message. Whether this file fits is decided
    // in the write, after a retry of an upload that was already stored has been answered.
    let limit = || async {
        let mut conn = state.db.acquire().await?;
        Ok::<_, ApiError>(settings::read(&mut conn).await?.file_limit_mb)
    };
    let announced = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok());
    if announced.is_some_and(|length| length > CEILING as u64) {
        return Err(too_large(limit().await?));
    }
    // A few bodies at a time, so uploads cannot fill the memory between them.
    let _permit = state
        .uploads
        .acquire()
        .await
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "Try again.".into()))?;
    let data = match axum::body::to_bytes(body, CEILING).await {
        Ok(data) => data.to_vec(),
        Err(error) => {
            let is_limit = std::error::Error::source(&error)
                .is_some_and(|source| source.is::<http_body_util::LengthLimitError>());
            if is_limit {
                return Err(too_large(limit().await?));
            }
            return Err(ApiError::bad("The file did not arrive in full."));
        }
    };
    let (sha256, size, data) =
        tokio::task::spawn_blocking(move || (sha256_hex(&data), picture_size(&data), data))
            .await
            .map_err(|_| ApiError::bad("The file could not be read."))?;
    let path = uri.path().to_owned();
    // Everything that ends up stored, so a key that comes back with another file is refused.
    let fingerprint = hash(
        &json!({
            "method": "POST",
            "path": path,
            "sha256": sha256,
            "name": name,
            "mime": mime,
            "upload_id": upload_id,
        })
        .to_string(),
    );
    let upload = Upload {
        name,
        mime,
        upload_id,
        sha256,
        size,
        data,
    };
    items::commit(
        &state,
        &identity,
        &Method::POST,
        &path,
        &key,
        fingerprint,
        Payload::File(upload),
    )
    .await
}

// What a file belongs to: an item or a note. Both keep their files the same way, a list on
// their row and the bytes in a table of their own, and a file is always looked up together
// with its holder.
#[derive(Clone, Copy)]
pub(crate) enum Holder {
    Item(i64),
    Note(i64),
}

impl Holder {
    fn id(self) -> i64 {
        match self {
            Self::Item(id) | Self::Note(id) => id,
        }
    }

    fn kind(self) -> &'static str {
        match self {
            Self::Item(_) => "item",
            Self::Note(_) => "note",
        }
    }

    fn about(self) -> About {
        match self {
            Self::Item(id) => About::Item(id),
            Self::Note(id) => About::Note(id),
        }
    }

    fn select_data(self) -> &'static str {
        match self {
            Self::Item(_) => "SELECT data FROM item_files WHERE id = ? AND item_id = ?",
            Self::Note(_) => "SELECT data FROM note_files WHERE id = ? AND note_id = ?",
        }
    }

    // The holder's files, through the hidden filter, and whether it is in the trash.
    async fn files(
        self,
        conn: &mut SqliteConnection,
        identity: &Identity,
    ) -> Result<(Vec<FileRef>, bool)> {
        Ok(match self {
            Self::Item(id) => {
                let item = visible_item(&mut *conn, id, identity).await?;
                (item.files.0, item.trashed)
            }
            Self::Note(id) => {
                let note = visible_note(&mut *conn, id, identity).await?;
                (note.files, note.trashed)
            }
        })
    }

    // The files of the holder a write is about. Hidden from this token or missing: 404, as for
    // any read.
    async fn open(self, conn: &mut SqliteConnection, identity: &Identity) -> Result<Vec<FileRef>> {
        let (files, trashed) = self.files(conn, identity).await?;
        if trashed {
            return Err(ApiError::bad(format!(
                "This {} is in the trash. Restore it before changing its files.",
                self.kind()
            )));
        }
        Ok(files)
    }

    async fn store(
        self,
        conn: &mut SqliteConnection,
        identity: &Identity,
        files: &[FileRef],
    ) -> Result<Written> {
        let seq = next_seq(conn).await?;
        let list = json!(files).to_string();
        let body = match self {
            Self::Item(id) => json!(
                sqlx::query_as::<_, Item>(concat!(
                    "UPDATE items SET files = ?, version = version + 1, seq = ?, updated_by = ?, \
                     updated_at = ",
                    now!(),
                    " WHERE id = ? RETURNING *"
                ))
                .bind(list)
                .bind(seq)
                .bind(&identity.actor.id)
                .bind(id)
                .fetch_one(&mut *conn)
                .await?
            ),
            Self::Note(id) => json!(
                sqlx::query_as::<_, Note>(concat!(
                    "UPDATE notes SET files = ?, version = version + 1, seq = ?, updated_by = ?, \
                     updated_at = ",
                    now!(),
                    " WHERE id = ? RETURNING *"
                ))
                .bind(list)
                .bind(seq)
                .bind(&identity.actor.id)
                .bind(id)
                .fetch_one(&mut *conn)
                .await?
            ),
        };
        Ok(Written {
            resource: self.kind(),
            id: self.id().to_string(),
            body,
        })
    }
}

pub(crate) async fn add(
    conn: &mut SqliteConnection,
    identity: &Identity,
    holder: Holder,
    upload: Upload,
) -> Result<Written> {
    let mut files = holder.open(conn, identity).await?;
    if files.len() >= PER_HOLDER {
        return Err(ApiError::bad(match holder {
            Holder::Item(_) => "An item can hold at most 40 files.",
            Holder::Note(_) => "A note can hold at most 40 files.",
        }));
    }
    // Read in the transaction, so a limit lowered a moment ago already counts.
    let limit = settings::read(conn).await?.file_limit_mb;
    if upload.data.len() as u64 > limit as u64 * MB {
        return Err(too_large(limit));
    }
    let bytes = upload.data.len() as i64;
    let insert = match holder {
        Holder::Item(_) => "INSERT INTO item_files(item_id, data) VALUES (?, ?) RETURNING id",
        Holder::Note(_) => "INSERT INTO note_files(note_id, data) VALUES (?, ?) RETURNING id",
    };
    let file: i64 = sqlx::query_scalar(insert)
        .bind(holder.id())
        .bind(upload.data)
        .fetch_one(&mut *conn)
        .await?;
    files.push(FileRef {
        id: file,
        name: upload.name.clone(),
        mime: upload.mime,
        bytes,
        sha256: upload.sha256,
        upload_id: upload.upload_id,
        width: upload.size.map(|(width, _)| width),
        height: upload.size.map(|(_, height)| height),
    });
    let written = holder.store(conn, identity, &files).await?;
    record(
        conn,
        holder.about(),
        &identity.actor.id,
        "file_added",
        json!({"file_id": file, "name": upload.name, "bytes": bytes}),
    )
    .await?;
    Ok(written)
}

// The item route, which the old image route shares.
pub(crate) async fn remove(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    file: i64,
    fields: Map<String, Value>,
) -> Result<Written> {
    remove_from(conn, identity, Holder::Item(id), file, fields).await
}

pub(crate) async fn remove_from(
    conn: &mut SqliteConnection,
    identity: &Identity,
    holder: Holder,
    file: i64,
    fields: Map<String, Value>,
) -> Result<Written> {
    if !fields.is_empty() {
        return Err(ApiError::bad("Removing a file takes no fields."));
    }
    let mut files = holder.open(conn, identity).await?;
    // The file has to be one of this holder's. Its ID under another is not found.
    let Some(at) = files.iter().position(|entry| entry.id == file) else {
        return Err(ApiError::missing());
    };
    let gone = files.remove(at);
    let delete = match holder {
        Holder::Item(_) => "DELETE FROM item_files WHERE id = ? AND item_id = ?",
        Holder::Note(_) => "DELETE FROM note_files WHERE id = ? AND note_id = ?",
    };
    sqlx::query(delete)
        .bind(file)
        .bind(holder.id())
        .execute(&mut *conn)
        .await?;
    let written = holder.store(conn, identity, &files).await?;
    record(
        conn,
        holder.about(),
        &identity.actor.id,
        "file_removed",
        json!({"file_id": file, "name": gone.name, "sha256": gone.sha256}),
    )
    .await?;
    Ok(written)
}

// `GET /api/items/<id>/files/<file>`, which the old image route shares.
pub async fn download(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, file)): Path<(String, String)>,
) -> Result<Response> {
    identity.require("read")?;
    let holder = Holder::Item(item_id(&id)?);
    serve(state, identity, holder, item_id(&file)?).await
}

// `GET /api/notes/<id>/files/<file>`.
pub async fn download_from_note(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, file)): Path<(String, String)>,
) -> Result<Response> {
    identity.require("read")?;
    let holder = Holder::Note(item_id(&id)?);
    serve(state, identity, holder, item_id(&file)?).await
}

// The bytes of one file. The holder decides who may see it, and the file is looked up under
// that holder: an agent cannot reach the file of a hidden item or note through one it may see.
// A file can hold anything, a web page too, so it is sent as a download that a browser must not
// run.
async fn serve(state: AppState, identity: Identity, holder: Holder, file: i64) -> Result<Response> {
    // Taken before the file is read and held by the body below, so a few files at a time are
    // in memory, however many clients ask or however slowly they read.
    let permit = state
        .downloads
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "Try again.".into()))?;
    let mut tx = state.db.begin().await?;
    let (files, _) = holder.files(&mut tx, &identity).await?;
    let Some(entry) = files.into_iter().find(|entry| entry.id == file) else {
        return Err(ApiError::missing());
    };
    let data: Vec<u8> = sqlx::query_scalar(holder.select_data())
        .bind(file)
        .bind(holder.id())
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(ApiError::missing)?;
    drop(tx);
    let length = HeaderValue::from(data.len());
    // The permit lives with the bytes: every chunk shares them, and a chunk may still wait in
    // the connection after the body is gone, so the permit goes when the last chunk does.
    let data = axum::body::Bytes::from_owner(Held {
        data,
        _permit: permit,
    });
    let body = Body::from_stream(futures_util::stream::unfold(data, |mut rest| async move {
        if rest.is_empty() {
            return None;
        }
        let chunk = rest.split_to(rest.len().min(CHUNK));
        Some((Ok::<_, std::convert::Infallible>(chunk), rest))
    }));
    let mime = HeaderValue::from_str(&entry.mime)
        .unwrap_or(HeaderValue::from_static("application/octet-stream"));
    let disposition = HeaderValue::from_str(&format!(
        "attachment; filename*=UTF-8''{}",
        utf8_percent_encode(&entry.name, NON_ALPHANUMERIC)
    ))
    .unwrap_or(HeaderValue::from_static("attachment"));
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (header::CONTENT_DISPOSITION, disposition),
            (
                header::X_CONTENT_TYPE_OPTIONS,
                HeaderValue::from_static("nosniff"),
            ),
            (
                header::CONTENT_SECURITY_POLICY,
                HeaderValue::from_static("sandbox"),
            ),
            (header::CONTENT_LENGTH, length),
        ],
        body,
    )
        .into_response())
}

// A downloaded file with the permit it was read under.
struct Held {
    data: Vec<u8>,
    _permit: tokio::sync::OwnedSemaphorePermit,
}

impl AsRef<[u8]> for Held {
    fn as_ref(&self) -> &[u8] {
        &self.data
    }
}

// For the old image route, whose JSON body of up to 8 MB is read before its handler runs: it
// waits for its place among the uploads here, so it counts against the same limit.
pub async fn one_of_the_uploads(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    let Ok(_permit) = state.uploads.acquire().await else {
        return ApiError(StatusCode::SERVICE_UNAVAILABLE, "Try again.".into()).into_response();
    };
    next.run(request).await
}
