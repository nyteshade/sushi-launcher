import SwiftUI

/// Renders one registry option with the control its kind calls for.
/// Everything (form rows, argument building, persistence, command preview)
/// flows from the single SushiOptionRegistry table.
struct OptionRow: View {
    @EnvironmentObject var model: AppModel
    let option: SushiOption

    private var isPassed: Bool {
        model.config.assignment(for: option).included
    }

    private var refusesForCurrentFamily: Bool {
        option.unsupported.contains(model.family) && isPassed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            controls
            HStack(alignment: .top, spacing: 4) {
                if refusesForCurrentFamily {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("\(model.family.label) refuses \(option.flagName) at load — sushi will stop with an error naming the flag.")
                }
                Text(option.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var controls: some View {
        switch option.kind {
        case .presence:
            Toggle(option.title, isOn: model.presenceBinding(option))

        case .onOff:
            Picker(selection: model.onOffBinding(option)) {
                Text("Server default").tag(-1)
                Text("\(option.flagName)  (on)").tag(1)
                Text("\(option.negationName)  (off)").tag(0)
            } label: {
                Text(option.title)
            }
            .pickerStyle(.menu)
            .fixedSize()

        case .int:
            includedRow {
                TextField("", value: model.intBinding(option), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .multilineTextAlignment(.trailing)
                    .disabled(!isPassed)
            }

        case .double:
            includedRow {
                TextField("", value: model.doubleBinding(option),
                          format: .number.precision(.fractionLength(0...6)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .multilineTextAlignment(.trailing)
                    .disabled(!isPassed)
            }

        case .text:
            includedRow {
                TextField("", text: model.stringBinding(option), prompt: Text(textPrompt))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
            }

        case .choice(let values):
            includedRow {
                Picker("", selection: model.stringBinding(option)) {
                    ForEach(values, id: \.self) { value in
                        Text(value == defaultChoice ? "\(value)  (default)" : value).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(!isPassed)
            }
        }
    }

    private var textPrompt: String {
        if case .text(let d) = option.kind, !d.isEmpty { return "default: \(d)" }
        return "value"
    }

    private var defaultChoice: String {
        if case .choice(let values) = option.kind { return values.first ?? "" }
        return ""
    }

    /// Row with the "pass this flag" checkbox; the editor is the trailing control.
    @ViewBuilder
    private func includedRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: model.includedBinding(option)) {
                Text(option.title)
                    .lineLimit(1)
                    .frame(minWidth: 170, alignment: .leading)
            }
            content()
            Spacer(minLength: 0)
        }
    }
}
