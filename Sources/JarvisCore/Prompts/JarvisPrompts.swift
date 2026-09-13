/// Namespace for predefined text sent to AI models.
///
/// The files in this directory, plus the coach tools in `Coach/Tools/`, are the audit surface. Each
/// tool file holds everything the model sees of that tool: its name, description, schema, guidance,
/// and the result text the harness sends back. Every other app-owned instruction, description,
/// wrapper, and observation sent to a model belongs in the matching domain extension here. Keep
/// transport payloads and dynamic user/session content with their owning subsystems.
public enum JarvisPrompts {}
