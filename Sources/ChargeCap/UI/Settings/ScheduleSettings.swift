import SwiftUI

struct ScheduleSettingsPane: View {
    @ObservedObject private var schedule = ScheduleManager.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var editing: ScheduledTask?
    @State private var isNew = false

    var body: some View {
        Form {
            Section {
                if schedule.tasks.isEmpty {
                    Text("No scheduled tasks").foregroundStyle(.secondary)
                }
                ForEach(schedule.tasks) { task in
                    HStack(spacing: 10) {
                        Image(systemName: task.action.symbolName)
                            .frame(width: 22)
                            .foregroundStyle(task.isEnabled ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.name)
                            Text(task.summaryText).font(.caption).foregroundStyle(.secondary)
                            if let next = schedule.nextOccurrence(of: task) {
                                Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button { isNew = false; editing = task } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit")
                        Button(role: .destructive) { schedule.removeTask(id: task.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete")
                        Toggle("Enabled", isOn: Binding(
                            get: { task.isEnabled },
                            set: { _ in schedule.toggleTask(id: task.id) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                Button {
                    isNew = true
                    editing = ScheduledTask(name: "New Task")
                } label: {
                    Label("Add Task…", systemImage: "plus")
                }
            } header: {
                Text("Scheduled Tasks")
            }

            Section {
                Toggle("Run missed tasks when the Mac wakes", isOn: $prefs.scheduleCatchUpMissed)
            } footer: {
                FootnoteText("If the Mac was asleep or off at the scheduled time, the task runs once as soon as ChargeCap can.")
            }

            Section {
                if schedule.history.isEmpty {
                    Text("No tasks have run yet").foregroundStyle(.secondary)
                } else {
                    ForEach(schedule.history.prefix(10)) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(run.taskName)
                                if run.wasCatchUp { Text("catch-up").font(.caption2).foregroundStyle(.orange) }
                                Spacer()
                                Text(run.firedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(run.actionTitle) · \(run.result)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear History", role: .destructive) { schedule.clearHistory() }
                }
            } header: {
                Text("History")
            }
        }
        .settingsPane()
        .sheet(item: $editing) { task in
            ScheduleTaskEditor(task: task, isNew: isNew) { saved in
                if let idx = schedule.tasks.firstIndex(where: { $0.id == saved.id }) {
                    schedule.tasks[idx] = saved
                } else {
                    schedule.addTask(saved)
                }
            }
        }
    }
}
