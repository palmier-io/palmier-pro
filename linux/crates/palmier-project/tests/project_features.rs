use std::fs;

use palmier_project::{
    ClipType, ImportRoot, MediaKind, MediaManifest, MediaManifestEntry, MediaSource,
    RecentProjectRegistry, SourceResolver, media_kind_for_extension, plan_imports, safe_filename,
    unique_filename,
};
use tempfile::TempDir;

fn manifest_entry(
    id: &str,
    name: &str,
    media_type: ClipType,
    source: MediaSource,
) -> MediaManifestEntry {
    MediaManifestEntry {
        id: id.to_owned(),
        name: name.to_owned(),
        media_type,
        source,
        duration: 1.0,
        generation_input: None,
        source_width: None,
        source_height: None,
        source_fps: None,
        has_audio: None,
        folder_id: None,
        cached_remote_url: None,
        cached_remote_url_expires_at: None,
        generation_status: None,
        import_input: None,
    }
}

#[tokio::test]
async fn recent_registry_deduplicates_and_persists_projects() {
    let temporary = TempDir::new().unwrap();
    let registry_path = temporary.path().join("registry.json");
    let project = temporary.path().join("Example.palmier");
    fs::create_dir(&project).unwrap();
    let registry = RecentProjectRegistry::open(&registry_path).await.unwrap();

    let first = registry.register(&project).await.unwrap();
    let second = registry.register(&project).await.unwrap();

    assert_eq!(first.id, second.id);
    assert!(second.last_opened_date > first.last_opened_date);
    assert_eq!(registry.entries().await.len(), 1);
    let reopened = RecentProjectRegistry::open(&registry_path).await.unwrap();
    assert_eq!(reopened.entries().await, registry.entries().await);
}

#[tokio::test]
async fn import_plan_keeps_supported_files_and_folder_structure() {
    let temporary = TempDir::new().unwrap();
    let root = temporary.path().join("Footage");
    let nested = root.join("Day 1");
    fs::create_dir_all(&nested).unwrap();
    fs::write(root.join("camera.MP4"), b"video").unwrap();
    fs::write(nested.join("room.wav"), b"audio").unwrap();
    fs::write(nested.join("notes.txt"), b"ignored").unwrap();
    fs::write(root.join(".hidden.mov"), b"hidden").unwrap();

    let plan = plan_imports([ImportRoot::new(&root)]).await.unwrap();

    assert_eq!(plan.folders.len(), 2);
    assert_eq!(plan.files.len(), 2);
    assert!(plan.files.iter().any(|file| file.kind == MediaKind::Video));
    assert!(plan.files.iter().any(|file| file.kind == MediaKind::Audio));
    assert!(plan.rejected_unsupported_names.is_empty());
    assert_eq!(media_kind_for_extension(".webp"), Some(MediaKind::Image));
}

#[test]
fn filenames_are_safe_and_unique() {
    let temporary = TempDir::new().unwrap();
    fs::write(temporary.path().join("clip.mp4"), b"existing").unwrap();

    assert_eq!(safe_filename("../../clip.mp4", "media"), "clip.mp4");
    assert_eq!(
        unique_filename(temporary.path(), "../../clip.mp4").unwrap(),
        "clip-1.mp4"
    );
}

#[tokio::test]
async fn source_resolution_handles_external_and_project_media() {
    let temporary = TempDir::new().unwrap();
    let package = temporary.path().join("Sources.palmier");
    let internal = package.join("media/internal.mp4");
    let external = temporary.path().join("external.wav");
    fs::create_dir_all(internal.parent().unwrap()).unwrap();
    fs::write(&internal, b"internal").unwrap();
    fs::write(&external, b"external").unwrap();
    let manifest = MediaManifest {
        entries: vec![
            manifest_entry(
                "internal",
                "Internal",
                ClipType::Video,
                MediaSource::Project {
                    relative_path: "media/internal.mp4".to_owned(),
                },
            ),
            manifest_entry(
                "external",
                "External",
                ClipType::Audio,
                MediaSource::External {
                    absolute_path: external.to_string_lossy().into_owned(),
                },
            ),
        ],
        ..MediaManifest::default()
    };
    let resolver = SourceResolver::new(manifest, Some(package));

    assert_eq!(resolver.resolve("internal").await.unwrap(), Some(internal));
    assert_eq!(resolver.resolve("external").await.unwrap(), Some(external));
    assert!(resolver.missing_asset_ids().await.unwrap().is_empty());
}
