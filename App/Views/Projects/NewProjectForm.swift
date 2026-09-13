import SwiftUI

/// The new-project form, shared by the launch flow and the footer switcher (so the two never drift).
/// The project's name is the folder Formora creates at the chosen location.
struct NewProjectForm: View {
    enum Layout {
        case launch
        case menu

        var summaryHeight: CGFloat { self == .launch ? 130 : 96 }
        var fieldSpacing: CGFloat { self == .launch ? 20 : 14 }
        var metrics: FieldMetrics { self == .launch ? .form : .detail }
    }

    let layout: Layout
    let session: ProjectSession
    let onCancel: () -> Void
    let onCreated: (String) -> Void
    /// The cold start (9f): the project is only registered here — it opens at the flow's last step.
    var onRegistered: ((ProjectRecord) -> Void)? = nil

    @State private var name = ""
    @State private var location: PickedFolder?
    @State private var summary = ""
    @State private var failure: String?

    private var trimmedName: String { ProjectNameRule.normalized(name) }

    /// Shown as soon as the name is invalid — but an empty field only disables the button.
    private var nameMessage: String? {
        if let problem = ProjectNameRule.problem(with: name), problem != .empty {
            return ProjectNameRule.message(for: problem)
        }
        if let location, !trimmedName.isEmpty,
           FileManager.default.fileExists(atPath: location.url.appendingPathComponent(trimmedName).path) {
            return ProjectFolderError.alreadyExists.message
        }
        return nil
    }

    private var canCreate: Bool {
        ProjectNameRule.problem(with: name) == nil && location != nil && nameMessage == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                FormLabel(text: "项目名称")
                FormoraTextField(placeholder: "例如 cart_recovery", text: $name, metrics: layout.metrics,
                                 isInvalid: nameMessage != nil, identifier: "newProject.name")
                if let nameMessage { InlineError(text: nameMessage, identifier: "newProject.nameError") }
            }
            .padding(.bottom, layout.fieldSpacing)

            VStack(alignment: .leading, spacing: 0) {
                FormLabel(text: "项目位置")
                locationControl
                if let location, !trimmedName.isEmpty {
                    Text("将创建 \(PathText.abbreviate(location.url.appendingPathComponent(trimmedName).path))")
                        .font(FormoraFont.mono(10.5))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 6)
                        .accessibilityIdentifier("newProject.target")
                }
            }
            .padding(.bottom, layout.fieldSpacing)

            VStack(alignment: .leading, spacing: 0) {
                FormLabel(text: "项目简介", optional: true)
                FormoraTextEditor(placeholder: "这个项目大概是做什么的（以后可以随时改）", text: $summary,
                                  height: layout.summaryHeight, metrics: layout.metrics, identifier: "newProject.summary")
            }
            .padding(.bottom, layout.fieldSpacing)

            if let failure { InlineError(text: failure, identifier: "newProject.failure").padding(.bottom, 8) }

            HStack(spacing: 18) {
                Button("取消", action: onCancel)
                    .buttonStyle(FormoraButtonStyle(kind: .standard, fillsWidth: true))
                    .accessibilityIdentifier("newProject.cancel")
                Button("创建项目", action: create)
                    .buttonStyle(FormoraButtonStyle(kind: .primary, fillsWidth: true))
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("newProject.create")
            }
        }
    }

    @ViewBuilder private var locationControl: some View {
        if let location {
            HStack(spacing: 10) {
                IconView(Icons.files, size: 15).foregroundStyle(Palette.accent.color)
                Text(PathText.abbreviate(location.url.path))
                    .font(FormoraFont.mono(12))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("newProject.location")
                Spacer(minLength: 0)
                Button("更改", action: pickLocation)
                    .buttonStyle(.plain)
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.accent.color)
                    .accessibilityIdentifier("newProject.changeLocation")
            }
            .padding(.horizontal, layout.metrics.horizontalPadding)
            .frame(height: layout.metrics.height)
            .background(RoundedRectangle(cornerRadius: layout.metrics.cornerRadius, style: .continuous)
                .fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: layout.metrics.cornerRadius, style: .continuous)
                .strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        } else {
            Button(action: pickLocation) {
                HStack(spacing: 10) {
                    IconView(Icons.files, size: 15)
                    Text("选择位置…").font(FormoraFont.ui(13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.inkMuted.color)
                .padding(.horizontal, layout.metrics.horizontalPadding)
                .frame(height: layout.metrics.height)
                .background(RoundedRectangle(cornerRadius: layout.metrics.cornerRadius, style: .continuous)
                    .fill(Palette.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: layout.metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择位置")
            .accessibilityIdentifier("newProject.pickLocation")
        }
    }

    private func pickLocation() {
        if let picked = session.pickLocation() { location = picked }
    }

    private func create() {
        guard canCreate, let location else { return }
        do {
            if let onRegistered {
                let record = try session.registerNewProject(named: name, in: location, summary: summary)
                failure = nil
                onRegistered(record)
            } else {
                try session.createProject(named: name, in: location, summary: summary)
                failure = nil
                onCreated(trimmedName)
            }
        } catch let error as ProjectFolderError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
    }
}
