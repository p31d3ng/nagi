import Foundation

/// A missing remembered UID remains selected; enumeration never supplies a fallback.
public enum InputSelection {
    public static func message(uid: String, devices: [InputDevice]) -> String {
        if !uid.isEmpty && !devices.contains(where: { $0.id == uid }) {
            return "Selected input disconnected"
        }
        if devices.isEmpty { return "No input devices available" }
        return uid.isEmpty ? "Choose an input" : devices.first { $0.id == uid }!.name
    }
    public static func persist(
        uid: String, devices: [InputDevice], recording: Bool, store: Store
    ) throws {
        guard !recording else { throw JournalError("Stop recording before changing the input.") }
        guard uid.isEmpty || devices.contains(where: { $0.id == uid }) else {
            throw JournalError(
                "That input disconnected. Choose a connected input; no fallback was selected.")
        }
        try store.set("inputUID", uid)
    }
}
