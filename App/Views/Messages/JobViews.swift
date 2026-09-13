import SwiftUI

/// 10f: the conversation's commands running in the background, docked above the composer with the plan — each with
/// how long it has run, and 停止 (the Agent is told).
struct BackgroundJobsStrip: View {
    let jobs: [BackgroundJobs.Job]
    let stop: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("后台命令").font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                Text("\(jobs.count) 条在运行").font(FormoraFont.mono(11)).foregroundStyle(Palette.inkFaint.color)
            }
            ForEach(jobs) { job in
                HStack(spacing: 8) {
                    IconView(Icons.terminal, size: 12).foregroundStyle(Palette.inkFaint.color)
                    Text(Self.line(job.command))
                        .font(FormoraFont.mono(11.5))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(job.id) · \(BackgroundJobs.elapsed(context.date.timeIntervalSince(job.startedAt)))")
                            .font(FormoraFont.mono(10.5))
                            .foregroundStyle(Palette.inkFaint.color)
                    }
                    SmallButton(title: "停止", identifier: "jobs.stop") { stop(job.id) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("jobs.row")
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jobs.strip")
    }

    static func line(_ command: String) -> String {
        command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
    }
}
