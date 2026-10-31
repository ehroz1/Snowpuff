//! What the update check needs from a GitHub release, without a JSON parser or a crypto crate.

pub fn newer(candidate: &str, current: &str) -> bool {
    let parse = |version: &str| -> Vec<u64> { version.split('.').map(|part| part.parse().unwrap_or(0)).chain([0; 3]).take(3).collect() };
    parse(candidate) > parse(current)
}

/// The string value of the first `key` in GitHub's JSON, without a JSON parser for one field.
pub fn field<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let rest = &json[json.find(&format!("\"{key}\""))? + key.len() + 2..];
    let rest = rest.trim_start().strip_prefix(':')?.trim_start().strip_prefix('"')?;
    Some(&rest[..rest.find('"')?])
}

/// The SHA-256 GitHub reports for the release asset called `name`, in lowercase hex, if the release has that asset.
/// The outer `Option` is whether the asset is there; the inner one whether GitHub gave its digest.
pub fn asset_digest(json: &str, name: &str) -> Option<Option<String>> {
    let quoted = format!("\"{name}\"");
    let start = json.match_indices("\"name\"").find_map(|(at, _)| {
        let rest = json[at + 6..].trim_start().strip_prefix(':')?.trim_start();
        rest.starts_with(&quoted).then_some(at)
    })?;
    // An asset's fields end with its download link; its digest comes before that.
    let asset = &json[start..];
    let asset = &asset[..asset.find("\"browser_download_url\"").unwrap_or(asset.len())];
    let digest = field(asset, "digest")
        .and_then(|digest| digest.strip_prefix("sha256:"))
        .filter(|hex| hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_ascii_lowercase);
    Some(digest)
}

/// SHA-256 of `data` in lowercase hex, to check a downloaded installer against the digest GitHub reports.
pub fn sha256(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
        0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
        0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
        0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
        0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in message.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(choice).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(majority);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (state, value) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *state = state.wrapping_add(value);
        }
    }
    h.iter().map(|word| format!("{word:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_versions() {
        assert!(newer("0.4.0", "0.3.1"));
        assert!(newer("1.0", "0.9.9"));
        assert!(newer("1.10.0", "1.9.0"));
        assert!(!newer("0.4.0", "0.4.0"));
        assert!(!newer("0.3.9", "0.4.0"));
    }

    #[test]
    fn reads_a_field() {
        assert_eq!(field(r#"{"url":"x","tag_name": "v0.4.0","name":"Snowpuff 0.4.0"}"#, "tag_name"), Some("v0.4.0"));
        assert_eq!(field(r#"{"name":"x"}"#, "tag_name"), None);
    }

    #[test]
    fn finds_an_asset_and_its_digest() {
        let hex = "ab".repeat(32);
        let json = format!(
            r#"{{"tag_name":"v1.1.0","name":"Snowpuff 1.1.0","assets":[{{"name":"Snowpuff.zip","digest":"sha256:{}","browser_download_url":"z"}},{{"name":"Snowpuff-Setup.exe","uploader":{{"login":"x"}},"digest":"sha256:{hex}","browser_download_url":"e"}}]}}"#,
            "cd".repeat(32)
        );
        assert_eq!(asset_digest(&json, "Snowpuff-Setup.exe"), Some(Some(hex)));
        assert_eq!(asset_digest(&json, "Snowpuff.zip"), Some(Some("cd".repeat(32))));
        assert_eq!(asset_digest(&json, "Snowpuff.dmg"), None);
        // An older release without digests still counts, just unchecked.
        assert_eq!(asset_digest(r#"{"assets":[{"name": "Snowpuff.zip","digest":null,"browser_download_url":"z"}]}"#, "Snowpuff.zip"), Some(None));
    }

    #[test]
    fn hashes() {
        assert_eq!(sha256(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        let long = vec![b'a'; 1_000_000];
        assert_eq!(sha256(&long), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    }
}
