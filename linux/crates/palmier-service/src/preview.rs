use palmier_core::{EditorCommand, EditorSession, EditorSnapshot, MutationError, MutationReceipt};

#[derive(Debug, Clone)]
pub struct EditPreview {
    pub receipt: MutationReceipt,
    pub snapshot: EditorSnapshot,
    pub base_revision: u64,
}

pub fn preview_command(
    session: &EditorSession,
    command: EditorCommand,
) -> Result<EditPreview, MutationError> {
    let base_revision = session.revision();
    let (receipt, snapshot) = session.preview(command)?;
    Ok(EditPreview {
        receipt,
        snapshot,
        base_revision,
    })
}
