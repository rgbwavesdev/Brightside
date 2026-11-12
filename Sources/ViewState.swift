import SwiftUI

/// Same as SwiftUI's @State. In this SDK @ViewState is a compiler macro whose plugin ships only with
/// Xcode, so the app (built with the command-line tools) wraps the State type directly.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
