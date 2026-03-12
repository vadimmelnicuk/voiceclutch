import CoreML
import Foundation

extension MLMultiArray {
    func reset(to value: NSNumber) {
        let count = self.count

        switch dataType {
        case .float32:
            let pointer = dataPointer.bindMemory(to: Float.self, capacity: count)
            pointer.update(repeating: value.floatValue, count: count)
        case .double:
            let pointer = dataPointer.bindMemory(to: Double.self, capacity: count)
            pointer.update(repeating: value.doubleValue, count: count)
        case .int32:
            let pointer = dataPointer.bindMemory(to: Int32.self, capacity: count)
            pointer.update(repeating: value.int32Value, count: count)
        default:
            break
        }
    }
}
