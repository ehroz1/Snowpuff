//! Settings kept in a small file of their own, `%APPDATA%\Snowpuff\settings.json`, which uninstalling leaves in
//! place: installing Snowpuff again, or on another computer with the file copied over, brings every choice back.
//! The app and the installer both read and write it.

use std::collections::BTreeMap;
use std::path::PathBuf;

/// Every setting is a whole number: on/off as 1/0, choices as their index.
pub type Values = BTreeMap<String, u32>;

/// `%APPDATA%\Snowpuff\settings.json`: the roaming profile, which the uninstaller doesn't touch.
pub fn path() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|base| PathBuf::from(base).join("Snowpuff").join("settings.json"))
}

/// The saved settings, if there is a file.
pub fn read() -> Option<Values> {
    let text = std::fs::read_to_string(path()?).ok()?;
    Some(parse(&text))
}

/// Saves the settings, replacing the file in one step so a crash can't leave half of it.
pub fn write(values: &Values) -> std::io::Result<()> {
    let path = path().ok_or_else(|| std::io::Error::other("APPDATA isn't set"))?;
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let staged = path.with_extension("json.new");
    std::fs::write(&staged, format(values))?;
    std::fs::rename(&staged, &path)
}

/// Reads the flat object `format` writes; anything else in the file is skipped rather than refused.
pub fn parse(text: &str) -> Values {
    let mut values = Values::new();
    let body = text.trim().trim_start_matches('{').trim_end_matches('}');
    for pair in body.split(',') {
        let Some((key, value)) = pair.split_once(':') else { continue };
        let key = key.trim().trim_matches('"');
        let value = match value.trim() {
            "true" => Some(1),
            "false" => Some(0),
            number => number.parse::<u32>().ok(),
        };
        if let Some(value) = value
            && !key.is_empty()
        {
            values.insert(key.to_string(), value);
        }
    }
    values
}

pub fn format(values: &Values) -> String {
    let lines: Vec<String> = values.iter().map(|(key, value)| format!("  \"{key}\": {value}")).collect();
    format!("{{\n{}\n}}\n", lines.join(",\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let mut values = Values::new();
        values.insert("snowfall".into(), 2);
        values.insert("icicles".into(), 1);
        values.insert("ambienceVolume".into(), 75);
        assert_eq!(parse(&format(&values)), values);
    }

    #[test]
    fn reads_booleans_and_skips_junk() {
        let values = parse("{ \"melt\": true, \"rain\": false, \"name\": \"x\", broken, \"volume\": 40 }");
        assert_eq!(values.get("melt"), Some(&1));
        assert_eq!(values.get("rain"), Some(&0));
        assert_eq!(values.get("volume"), Some(&40));
        assert!(!values.contains_key("name"));
    }

    #[test]
    fn empty_file_is_no_settings() {
        assert!(parse("").is_empty());
        assert!(parse("{}").is_empty());
    }
}
