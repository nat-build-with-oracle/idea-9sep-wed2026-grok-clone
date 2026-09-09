import SwiftUI

struct RecipientPickerView: View {
  @ObservedObject var store: PreviewWorkspace
  @FocusState private var queryFocused: Bool
  @State private var groupName = "New group chat"
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("To:").foregroundStyle(ShellTheme.secondary)
        TextField("Search or create Bots", text: $store.pickerQuery)
          .textFieldStyle(.plain).font(.system(size: 17))
          .focused($queryFocused).accessibilityIdentifier("recipient-query")
          .onSubmit { commitHighlighted() }
          .onChange(of: store.pickerQuery) { _, _ in store.highlightedRecipient = 0 }
        ShellIconButton(symbol: "xmark", label: "Cancel new chat") { store.pickerMode = .closed }
      }.padding(.horizontal, 19).frame(height: 52)
      Rectangle().fill(ShellTheme.separator).frame(height: 1)
      if store.pickerMode == .group && !store.selectedRecipients.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(store.selectedRecipients, id: \.self) { id in
              if let bot = store.bots.first(where: { $0.id == id }) {
                HStack(spacing: 6) {
                  BotAvatar(color: bot.color, shape: bot.shape, size: 21)
                  Text(bot.name).font(.system(size: 12))
                  Button {
                    store.selectedRecipients.removeAll { $0 == id }
                  } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                  }
                  .buttonStyle(.plain).accessibilityLabel("Remove \(bot.name)")
                }.padding(7).background(ShellTheme.bubble, in: Capsule())
              }
            }
          }
        }.padding(.horizontal, 26).padding(.top, 13)
      }

      VStack(spacing: 2) {
        if store.pickerMode == .single {
          pickerAction("Create new Bot", symbol: "plus") { store.panel = .newBot }
          pickerAction("Create group chat", symbol: "person.2") { store.openPicker(group: true) }
        }
        ForEach(Array(store.availableRecipients.enumerated()), id: \.element.id) { index, bot in
          Button {
            store.selectRecipient(bot.id)
          } label: {
            HStack(spacing: 13) {
              BotAvatar(color: bot.color, shape: bot.shape, size: 28)
              Text(bot.name).font(.system(size: 16))
              Spacer(minLength: 0)
              if index == store.highlightedRecipient {
                Text(store.pickerMode == .group ? "Add to group chat" : "New chat")
                  .foregroundStyle(ShellTheme.secondary).font(.system(size: 13))
              }
            }.padding(.horizontal, 12).frame(height: 49).contentShape(Rectangle())
          }.buttonStyle(.plain)
            .background(
              index == store.highlightedRecipient ? Color(hex: 0x454545) : .clear,
              in: RoundedRectangle(cornerRadius: 9)
            )
            .disabled(store.pickerMode == .group && store.selectedRecipients.count >= 6)
            .accessibilityLabel("\(store.pickerMode == .group ? "Add" : "Chat with") \(bot.name)")
        }
        if store.availableRecipients.isEmpty {
          Text(store.selectedRecipients.count >= 6 ? "Six bots selected" : "No matching bots")
            .foregroundStyle(ShellTheme.secondary).padding(20)
        }
      }
      .padding(8).background(Color(hex: 0x2d2d2d), in: RoundedRectangle(cornerRadius: 17))
      .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.11)))
      .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
      .frame(maxWidth: 660).padding(.horizontal, 30).padding(.top, 8)

      if store.pickerMode == .group {
        HStack {
          TextField("Group name", text: $groupName).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("group-name")
          Button("Create group") {
            store.isSaving = true
            Task {
              defer { store.isSaving = false }
              do {
                try await store.performCreateGroup(
                  name: groupName, members: store.selectedRecipients)
              } catch { self.error = error.localizedDescription }
            }
          }.disabled(store.isSaving || store.selectedRecipients.count < 2).keyboardShortcut(
            .return, modifiers: .command
          )
          .accessibilityIdentifier("create-group")
        }.frame(maxWidth: 640).padding(.horizontal, 40).padding(.top, 20)
        Text(
          error
            ?? (store.isPersistent
              ? "Choose two to six bots. This group is saved on your Mac."
              : "Choose two to six bots. Group conversations are local previews.")
        )
        .font(.system(size: 12)).foregroundStyle(error == nil ? ShellTheme.secondary : .orange)
        .padding(.top, 8)
      }
      Spacer(minLength: 20)
    }
    .onAppear { queryFocused = true }
    .onMoveCommand { direction in
      let count = store.availableRecipients.count
      guard count > 0 else { return }
      switch direction {
      case .down: store.highlightedRecipient = min(count - 1, store.highlightedRecipient + 1)
      case .up: store.highlightedRecipient = max(0, store.highlightedRecipient - 1)
      default: break
      }
    }
  }

  private func pickerAction(_ title: String, symbol: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 13) {
        Image(systemName: symbol).font(.system(size: 17)).frame(width: 28, height: 28)
          .foregroundStyle(ShellTheme.secondary).background(.white.opacity(0.05), in: Circle())
        Text(title).font(.system(size: 16))
        Spacer()
      }.padding(.horizontal, 12).frame(height: 49).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }

  private func commitHighlighted() {
    let options = store.availableRecipients
    guard options.indices.contains(store.highlightedRecipient) else { return }
    store.selectRecipient(options[store.highlightedRecipient].id)
  }
}
