-- The price of a kWh in Swiss francs, which turns the energy an agent's machine reports into a
-- cost on the Agents screen. Unset until the owner enters one.
ALTER TABLE server_settings ADD COLUMN energy_price_chf REAL
    CHECK (energy_price_chf IS NULL OR energy_price_chf BETWEEN 0 AND 100);
