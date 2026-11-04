import Darwin
import Foundation

/// What this process is charged for, as Activity Monitor's Memory column
/// counts it: the physical footprint, which includes the Metal buffers a
/// model's weights sit in. What the Neural Engine holds for a CoreML model
/// is charged to the system's `aned`, not to us, so a speech model on the
/// Neural Engine shows here only in part.
public enum ProcessMemory {
    /// Bytes, or nil if the kernel would not say.
    public static var footprint: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }

    /// "1,234 MB".
    public static func describe(_ bytes: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: NSNumber(value: Double(bytes) / 1_048_576)) ?? "?") + " MB"
    }
}
