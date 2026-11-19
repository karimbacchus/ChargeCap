import SwiftUI

struct PopoverSettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                ForEach(prefs.popoverWidgetOrder) { widget in
                    HStack {
                        Toggle(widget.title, isOn: visibility(widget))
                        Spacer()
                        Button { move(widget, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(prefs.popoverWidgetOrder.first == widget)
                        Button { move(widget, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(prefs.popoverWidgetOrder.last == widget)
                    }
                    .buttonStyle(.borderless)
                }
                .onMove { source, destination in
                    prefs.popoverWidgetOrder.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("Widgets")
            } footer: {
                FootnoteText("Toggle which widgets appear in the menu bar popover and drag (or use the arrows) to reorder them.")
            }

            Section {
                Button("Reset to Default") {
                    prefs.popoverWidgetOrder = Prefs.defaultPopoverWidgetOrder
                    prefs.hiddenPopoverWidgets = Prefs.defaultHiddenPopoverWidgets
                }
            }
        }
        .settingsPane()
    }

    private func visibility(_ widget: PopoverWidget) -> Binding<Bool> {
        Binding(
            get: { !prefs.hiddenPopoverWidgets.contains(widget) },
            set: { visible in
                if visible { prefs.hiddenPopoverWidgets.remove(widget) } else { prefs.hiddenPopoverWidgets.insert(widget) }
            }
        )
    }

    private func move(_ widget: PopoverWidget, by delta: Int) {
        guard let idx = prefs.popoverWidgetOrder.firstIndex(of: widget) else { return }
        let target = idx + delta
        guard prefs.popoverWidgetOrder.indices.contains(target) else { return }
        prefs.popoverWidgetOrder.swapAt(idx, target)
    }
}
