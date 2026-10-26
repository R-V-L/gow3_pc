//! Packed ZArchive (.zar) game images: the game reads the image in place as /app0, while the
//! preparation scripts and the launcher need real files. This module reads the image's listing
//! through the probe and extracts the entries those tools read into a per-archive cache folder
//! (`out/zar`). Nothing is written beside the image, and the runtime never uses the cache.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

use super::host::Host;
use crate::core::platform::tool::{Stderr, ToolCall, Window};

/// The pause menu's Exit to Desktop row and the glyphs' button prompts.
pub const PAUSE_MENU_WAD: &str = "EXEC/WAD/PS4_LE/R_UI.WAD";
/// Every WAD `glyphs` reads (the button prompts, the QTE circle, the lyre's discs).
pub const GLYPH_WADS: &[&str] = &[
    PAUSE_MENU_WAD,
    "EXEC/WAD/PS4_LE/R_PERM.WAD",
    "EXEC/WAD/PS4_LE/OLY150.WAD",
];

/// What the preparation scripts and the launcher read from the image.
const VIEW: &[&str] = &["eboot.bin", "sce_module/", "sce_sys/"];

/// Whether a game choice is a .zar image (a folder holding one is not: pick the file).
pub fn is_archive(path: &Path) -> bool {
    path.is_file()
        && path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extension.eq_ignore_ascii_case("zar"))
}

/// Every folder and file of the image with its size, from `probe --zar-list`.
#[derive(Default)]
pub struct Listing {
    pub directories: Vec<String>,
    pub files: BTreeMap<String, u64>,
}

impl Listing {
    pub fn read(
        host: &dyn Host,
        env: &IndexMap<String, String>,
        probe: &Path,
        port: &Path,
        archive: &Path,
    ) -> Result<Self, String> {
        let output = run(
            host,
            env,
            probe,
            port,
            [OsString::from("--zar-list"), archive.as_os_str().to_owned()],
        )?;
        let mut listing = Listing::default();
        for line in output.lines() {
            let fields: Vec<&str> = line.split('\t').collect();
            match fields.as_slice() {
                ["z", _] => {}
                ["d", name] => listing.directories.push((*name).to_string()),
                ["f", size, name] => {
                    let size = size
                        .parse::<u64>()
                        .map_err(|_| format!("--zar-list: bad size in {line:?}"))?;
                    listing.files.insert((*name).to_string(), size);
                }
                _ => return Err(format!("--zar-list: unexpected line {line:?}")),
            }
        }
        Ok(listing)
    }

    /// The files an entry names: itself, or everything under it when it ends with a slash.
    pub fn files_in(&self, entry: &str) -> Vec<String> {
        if entry.ends_with('/') {
            self.files
                .keys()
                .filter(|name| name.starts_with(entry))
                .cloned()
                .collect()
        } else if self.files.contains_key(entry) {
            vec![entry.to_string()]
        } else {
            Vec::new()
        }
    }

    /// The listing as JSON, for the preparation scripts' resource census.
    pub fn write(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
        }
        let text = serde_json::to_string(&self.files).map_err(|error| error.to_string())?;
        fs::write(path, format!("{text}\n")).map_err(|error| format!("{}: {error}", path.display()))
    }
}

#[derive(Serialize, Deserialize)]
struct Marker {
    archive: String,
    size: u64,
    mtime_ns: u64,
}

/// The folder holding the image's `eboot.bin`, `sce_module/` and `sce_sys/`, extracted once;
/// `extra` names files to add for this start (the WADs the pause menu and the glyphs read).
#[allow(clippy::too_many_arguments)]
pub fn view(
    host: &dyn Host,
    env: &IndexMap<String, String>,
    probe: &Path,
    port: &Path,
    archive: &Path,
    cache: &Path,
    listing: &Listing,
    extra: &[&str],
) -> Result<PathBuf, String> {
    let status =
        fs::metadata(archive).map_err(|error| format!("{}: {error}", archive.display()))?;
    let mtime_ns = status
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let marker = Marker {
        archive: archive.to_string_lossy().into_owned(),
        size: status.len(),
        mtime_ns,
    };
    let folder = cache.join("game");
    let marker_path = cache.join("view.json");
    let current = fs::read_to_string(&marker_path)
        .ok()
        .and_then(|text| serde_json::from_str::<Marker>(&text).ok());
    let same = current.is_some_and(|current| {
        current.archive == marker.archive
            && current.size == marker.size
            && current.mtime_ns == marker.mtime_ns
    });
    if !same || !folder.join("eboot.bin").is_file() || !folder.join("sce_module").is_dir() {
        match fs::remove_dir_all(cache) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("{}: {error}", cache.display())),
        }
        fs::create_dir_all(&folder).map_err(|error| format!("{}: {error}", folder.display()))?;
        for directory in &listing.directories {
            let path = folder.join(directory);
            fs::create_dir_all(&path).map_err(|error| format!("{}: {error}", path.display()))?;
        }
        let wanted: Vec<String> = VIEW
            .iter()
            .flat_map(|entry| listing.files_in(entry))
            .collect();
        extract_all(host, env, probe, port, archive, &folder, &wanted)?;
        let text = serde_json::to_string(&marker).map_err(|error| error.to_string())?;
        fs::write(&marker_path, format!("{text}\n"))
            .map_err(|error| format!("{}: {error}", marker_path.display()))?;
    }
    let missing: Vec<String> = extra
        .iter()
        .flat_map(|entry| listing.files_in(entry))
        .filter(|name| !folder.join(name).is_file())
        .collect();
    if !missing.is_empty() {
        extract_all(host, env, probe, port, archive, &folder, &missing)?;
    }
    Ok(folder)
}

fn extract_all(
    host: &dyn Host,
    env: &IndexMap<String, String>,
    probe: &Path,
    port: &Path,
    archive: &Path,
    folder: &Path,
    entries: &[String],
) -> Result<(), String> {
    for entry in entries {
        let destination = folder.join(entry);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
        }
        run(
            host,
            env,
            probe,
            port,
            [
                OsString::from("--zar-extract"),
                archive.as_os_str().to_owned(),
                OsString::from(entry),
                destination.as_os_str().to_owned(),
            ],
        )?;
    }
    Ok(())
}

fn run(
    host: &dyn Host,
    env: &IndexMap<String, String>,
    probe: &Path,
    port: &Path,
    args: impl IntoIterator<Item = OsString>,
) -> Result<String, String> {
    let call = ToolCall {
        program: probe.as_os_str().to_owned(),
        args: args.into_iter().collect(),
        env: Some(env),
        cwd: Some(port),
        limit: None,
        stderr: Stderr::Inherit,
        window: Window::Hidden,
    };
    let output = host.run(&call).map_err(|error| error.to_string())?;
    if output.code != Some(0) {
        return Err(format!("{} failed", probe.display()));
    }
    Ok(output.stdout)
}
