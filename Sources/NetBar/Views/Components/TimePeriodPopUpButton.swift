import SwiftUI
import Cocoa

/// AppKit-backed period selector. SwiftUI's menu Picker currently creates
/// AttributeGraph cycles inside NSPopover on macOS 26.
struct TimePeriodPopUpButton: NSViewRepresentable {
    @Binding var selection: ProcessTrafficMonitor.TimePeriod

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        configure(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        configure(button)
    }

    private func configure(_ button: NSPopUpButton) {
        let titles = ProcessTrafficMonitor.TimePeriod.allCases.map(\.rawValue)
        if button.itemTitles != titles {
            button.removeAllItems()
            for period in ProcessTrafficMonitor.TimePeriod.allCases {
                button.addItem(withTitle: period.rawValue)
                button.lastItem?.representedObject = period.rawValue
            }
        }
        button.selectItem(withTitle: selection.rawValue)
    }

    class Coordinator: NSObject {
        var selection: Binding<ProcessTrafficMonitor.TimePeriod>

        init(selection: Binding<ProcessTrafficMonitor.TimePeriod>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let rawValue = sender.selectedItem?.representedObject as? String,
                  let period = ProcessTrafficMonitor.TimePeriod(rawValue: rawValue) else {
                return
            }
            selection.wrappedValue = period
        }
    }
}
