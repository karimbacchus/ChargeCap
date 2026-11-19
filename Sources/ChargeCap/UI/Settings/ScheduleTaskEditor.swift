import SwiftUI

struct ScheduleTaskEditor: View {
    @State var task: ScheduledTask
    let isNew: Bool
    let onSave: (ScheduledTask) -> Void
    @Environment(\.dismiss) private var dismiss

    private var usesLimit: Bool { task.action == .setChargeLimit || task.action == .startDischarge }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: task.hour, minute: task.minute, second: 0, of: Date()) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                task.hour = c.hour ?? 0
                task.minute = c.minute ?? 0
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $task.name)
                    Toggle("Enabled", isOn: $task.isEnabled)
                }
                Section("Action") {
                    Picker("Action", selection: $task.action) {
                        ForEach(ScheduleActionType.allCases) { Label($0.title, systemImage: $0.symbolName).tag($0) }
                    }
                    if usesLimit {
                        Stepper(value: $task.targetLimit, in: 10...100, step: 5) {
                            LabeledContent("Limit", value: "\(task.targetLimit)%")
                        }
                    }
                }
                Section("When") {
                    DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    Picker("Repeat", selection: $task.frequency) {
                        ForEach(ScheduleFrequency.allCases) { Text($0.title).tag($0) }
                    }
                    if task.frequency == .weekly {
                        Picker("Day", selection: $task.weekday) {
                            ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                    }
                    if task.frequency == .customDays {
                        HStack {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                    get: { task.weekdays.contains(day) },
                                    set: { if $0 { task.weekdays.insert(day) } else { task.weekdays.remove(day) } }
                                ))
                                .toggleStyle(.button)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    onSave(task)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(task.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || (task.frequency == .customDays && task.weekdays.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
    }
}
