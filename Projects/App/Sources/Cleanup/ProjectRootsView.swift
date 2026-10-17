import SwiftUI

/// 빌드 산출물을 찾을 프로젝트 폴더 목록. 홈 전체를 프로젝트 폴더로 두지 않는 이유는, 그러면
/// `~/.vscode/extensions/*/node_modules`처럼 다시 만들 수 없는 설치물까지 후보가 되기 때문이다(규칙 엔진이 일부 막기는 한다).
struct ProjectRootsView: View {
    @Bindable var model: CleanupModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosesFolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("프로젝트 폴더")
                .font(.title3.bold())
            Text("이 폴더들 안에서 node_modules, .build, DerivedData, Pods 같은 빌드 산출물을 찾습니다. 캐시와 시스템 항목은 폴더와 상관없이 찾습니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(CleanupModel.abbreviate(root))
                        Spacer()
                        Button("빼기", systemImage: "minus.circle") {
                            model.projectRoots.removeAll { $0 == root }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                if model.projectRoots.isEmpty {
                    Text("아직 없습니다. 개발 프로젝트를 모아 둔 폴더를 추가하세요.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("폴더 추가…") { choosesFolders = true }
                Spacer()
                Button("닫기") { dismiss() }
                Button("저장하고 다시 찾기") {
                    dismiss()
                    model.refresh()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 400)
        .fileImporter(isPresented: $choosesFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls where !model.projectRoots.contains(url.path) {
                model.projectRoots.append(url.path)
            }
        }
    }
}
