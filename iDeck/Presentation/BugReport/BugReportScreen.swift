// BugReportScreen.swift
// Split from BugReportView.swift (iDeck 3.0 architecture).

import SwiftUI

struct BugReportView: View {
    @StateObject private var model = BugReportModel()
    @State private var expanded: Set<String> = []
    // Both groups start collapsed: the report opens as a short summary.
    @State private var bugsOpen = false
    @State private var jitOpen = false
    @State private var showClearConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            List {
                if let finding = model.wineFinding {
                    Section(tr("Diagnosis")) {
                        Label(tr(finding), systemImage: "stethoscope")
                            .foregroundColor(.orange)
                    }
                }
                let jitIssues = model.issues.filter { $0.source == .jit }
                if !jitIssues.isEmpty {
                    Section {
                        if jitOpen { ForEach(jitIssues) { issue in issueRow(issue) } }
                    } header: {
                        Button { withAnimation { jitOpen.toggle() } } label: {
                            HStack {
                                Text(tr("JIT") + " (\(jitIssues.count))")
                                Spacer()
                                Image(systemName: "chevron.down").rotationEffect(.degrees(jitOpen ? 0 : -90))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                let gameIssues = model.issues.filter { $0.source != .jit }
                Section {
                    if model.isScanning && gameIssues.isEmpty {
                        HStack { ProgressView(); Text(tr("Reading logs...")).foregroundColor(.gray) }
                    } else if gameIssues.isEmpty {
                        Label(tr("No bugs found in the logs."), systemImage: "checkmark.seal")
                            .foregroundColor(.green)
                    } else if bugsOpen {
                        ForEach(gameIssues) { issue in issueRow(issue) }
                    }
                } header: {
                    // Show detected problems immediately. Users may collapse
                    // the section, but should never need to discover a hidden list.
                    Button {
                        withAnimation { bugsOpen.toggle() }
                    } label: {
                        HStack {
                            Text(tr("Bugs found") + (gameIssues.isEmpty ? "" : " (\(gameIssues.count))"))
                            Spacer()
                            if !gameIssues.isEmpty {
                                Image(systemName: "chevron.down").rotationEffect(.degrees(bugsOpen ? 0 : -90))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section(tr("Logs")) {
                    Button { model.copyAll() } label: {
                        Label(tr("Copy all bugs"), systemImage: "doc.on.doc")
                    }
                    .disabled(model.issues.isEmpty)
                    Button { model.copyWineLog() } label: {
                        Label(tr("Copy last Wine log"), systemImage: "terminal")
                    }
                    .disabled(!model.hasWineLog)
                    Button { model.copyLog(AppLog.fileURL) } label: {
                        Label(tr("Copy iDeck log"), systemImage: "list.bullet.rectangle")
                    }
                    .disabled(!model.hasAppLog)
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Label(tr("Clear logs"), systemImage: "trash")
                    }
                    // Always available: a log written after the last read, or one the
                    // download guard held, left this button greyed out as if empty.
                }
            }
            .scrollContentBackground(.hidden)
            // On the list, not next to the notice alert below: two .alert modifiers on
            // one view show only one of them, which left Clear logs doing nothing.
            // A centred alert over the whole Bugs & logs screen, not a popover on the button.
            .alert(tr("Clear diagnostic logs?"), isPresented: $showClearConfirmation) {
                Button(tr("Clear logs"), role: .destructive) { model.clearLogs() }
                Button(tr("Cancel"), role: .cancel) { }
            } message: {
                Text(tr("This action cannot be undone. Games and settings will not be changed."))
            }
        }
        .navigationTitle(tr("Bugs & logs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await model.scan(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isScanning)
            }
        }
        .task {
            // New errors may be written by Wine after the screen opens.
            // Rescan only while Bugs & logs is visible; cancellation stops
            // polling when the user leaves this page.
            await model.scan(force: true)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { break }
                guard !Task.isCancelled else { break }
                await model.scan()
            }
        }
        .alert(model.notice ?? "", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(tr("OK"), role: .cancel) {}
        }
    }

    private func issueRow(_ issue: LogIssue) -> some View {
        let isOpen = expanded.contains(issue.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: issue.severity > 1 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(issue.severity > 1 ? .red : .orange)
                Text(issue.source.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.12), in: Capsule())
                if issue.count > 1 {
                    Text("×\(issue.count)").font(.caption2).foregroundColor(.gray)
                }
                Spacer()
                Button { model.copy(issue) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(tr("Copy bug"))
            }
            Text(issue.line)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(isOpen ? nil : 2)
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(issue.id) } else { expanded.insert(issue.id) }
        }
    }
}
