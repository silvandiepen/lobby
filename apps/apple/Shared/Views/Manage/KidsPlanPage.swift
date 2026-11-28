// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import MapKit
import SwiftUI

/// "When and what" for one kids viewer: what holds now and buttons to change it at once, the
/// week, Ask first, who is asked, screen time, away, music and places (docs/kids-control.md, §4).
struct KidsPlanPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var editor: KidsPlanEditor
    @State private var editingBlock: BlockEdit?
    @State private var editingPlace: KidsPlace?
    private let name: String

    init(app: AppModel, profileID: String) {
        _editor = State(initialValue: KidsPlanEditor(app: app, profileID: profileID))
        name = app.profiles.first { $0.id == profileID }?.name ?? "this child"
    }

    var body: some View {
        @Bindable var editor = editor
        Form {
            if let view = editor.view {
                nowSection(view)
                weekSection
                askSection(view)
                screenTimeSection
                awaySection
                musicSection(view)
                placesSection
                lockSection(view)
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.lobbyBackground(scheme))
        .navigationTitle("When and What")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await editor.save() } }
                    .disabled(!editor.hasChanges || editor.isSaving)
                    .accessibilityIdentifier("kidsPlan.save")
            }
        }
        .task { await editor.load() }
        .sheet(item: $editingBlock) { edit in
            BlockEditor(edit: edit) { block in
                if let index = edit.index { editor.plan.blocks[index] = block } else { editor.plan.blocks.append(block) }
            } remove: {
                if let index = edit.index { editor.remove(block: index) }
            }
        }
        .sheet(item: $editingPlace) { place in
            PlaceEditor(place: place, isNew: !editor.plan.places.contains { $0.id == place.id }, nearby: editor.plan.places.first) { changed in
                if let index = editor.plan.places.firstIndex(where: { $0.id == changed.id }) {
                    editor.plan.places[index] = changed
                } else {
                    editor.plan.places.append(changed)
                }
            } remove: {
                editor.plan.places.removeAll { $0.id == place.id }
            }
        }
        .alert(
            "That did not work", isPresented: Binding(get: { editor.problem != nil }, set: { if !$0 { editor.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editor.problem ?? "")
        }
    }

    // MARK: Now

    private func nowSection(_ view: KidsPlanView) -> some View {
        Section {
            Text(KidsGlance.line(view.now))
                .font(.headline)
                .accessibilityIdentifier("kidsPlan.now")
            ForEach([KidsMode.nothing, .listening, .everything, .ask], id: \.self) { mode in
                Menu {
                    ForEach(KidsLengthChoice.choices) { choice in
                        Button(choice.title) { Task { await editor.override(mode, length: choice.length) } }
                    }
                } label: {
                    Label(KidsModeText.override(mode), systemImage: KidsModeText.symbol(mode))
                }
            }
            if view.now.at.reason == .override {
                Button("End It Now", role: .destructive) { Task { await editor.endOverride() } }
            }
            if view.now.at.grantId != nil {
                Button("Switch to Watch") { Task { await editor.switchAnswer(to: .watch) } }
                Button("Switch to Listen") { Task { await editor.switchAnswer(to: .listen) } }
                Button("End the Answer", role: .destructive) { Task { await editor.endAnswer() } }
            }
        } header: {
            Text("Now")
        } footer: {
            Text("What you set here holds over the week, the places and screen time until it ends.")
        }
    }

    // MARK: The week

    private var weekSection: some View {
        @Bindable var editor = editor
        return Section {
            Picker("The rest of the time", selection: $editor.plan.defaultMode) { modeOptions }
            KidsWeekGrid(plan: editor.plan) { index in
                editingBlock = BlockEdit(index: index, block: editor.plan.blocks[index])
            }
            ForEach(Array(editor.plan.blocks.enumerated()), id: \.offset) { index, block in
                Button {
                    editingBlock = BlockEdit(index: index, block: block)
                } label: {
                    LabeledContent(block.label ?? KidsModeText.name(block.mode)) {
                        Text("\(KidsModeText.days(block.days)) \(block.start)–\(block.end)")
                    }
                }
            }
            Button("Add a Time…", systemImage: AppSymbol.add) {
                editingBlock = BlockEdit(index: nil, block: KidsPlanBlock(days: [1, 2, 3, 4, 5], start: "08:00", end: "15:00", mode: .nothing))
            }
            Button("School Days") { editor.apply(KidsWeek.schoolDays) }
            Button("Bedtime") { editor.apply(KidsWeek.bedtime) }
        } header: {
            Text("The Week")
        } footer: {
            Text("School days: Monday to Friday 08:00–15:00, nothing. Bedtime: every day 19:30–07:00, only listening. Where times overlap, the stricter holds.")
        }
    }

    @ViewBuilder
    private var modeOptions: some View {
        ForEach([KidsMode.everything, .ask, .listening, .nothing], id: \.self) { mode in
            Text(KidsModeText.name(mode)).tag(mode)
        }
    }

    // MARK: Asking

    private func askSection(_ view: KidsPlanView) -> some View {
        @Bindable var editor = editor
        return Section {
            Picker("Ask first", selection: $editor.plan.askStyle) {
                Text("Ask to open").tag(KidsAskStyle.open)
                Text("Ask per title").tag(KidsAskStyle.title)
            }
            ForEach(view.grownUps) { grownUp in
                Toggle(
                    grownUp.name,
                    isOn: Binding(
                        get: { editor.isAsked(grownUp.profileId) },
                        set: { editor.setAsked($0, profileID: grownUp.profileId, deviceIDs: view.adminDevices.map(\.id)) }))
                if let asker = editor.plan.askers.first(where: { $0.profileId == grownUp.profileId }) {
                    ForEach(view.adminDevices) { device in
                        Toggle(
                            device.name,
                            isOn: Binding(
                                get: { asker.deviceIds.contains(device.id) },
                                set: { editor.setDevice(device.id, asked: $0, for: grownUp.profileId) })
                        )
                        .padding(.leading, AppTheme.Space.l)
                    }
                }
            }
        } header: {
            Text("Ask First")
        } footer: {
            Text("Ask to open: \(name) sees nothing until one of you answers Watch, Listen or No. Ask per title: \(name) looks and listens freely and asks for each film. The first answer counts.")
        }
    }

    // MARK: Screen time, away, music

    private var screenTimeSection: some View {
        @Bindable var editor = editor
        let on = Binding(
            get: { editor.plan.screenTime != nil },
            set: { editor.plan.screenTime = $0 ? KidsScreenTime(weekdayMinutes: 60, weekendMinutes: 120) : nil })
        return Section {
            Toggle("Limit Watching", isOn: on)
            if let time = editor.plan.screenTime {
                Stepper(
                    "School days: \(time.weekdayMinutes.map { "\($0) min" } ?? "no limit")",
                    value: Binding(get: { time.weekdayMinutes ?? 0 }, set: { editor.plan.screenTime?.weekdayMinutes = $0 }), in: 0...600, step: 15)
                Stepper(
                    "Weekends: \(time.weekendMinutes.map { "\($0) min" } ?? "no limit")",
                    value: Binding(get: { time.weekendMinutes ?? 0 }, set: { editor.plan.screenTime?.weekendMinutes = $0 }), in: 0...600, step: 15)
                Picker("Afterwards", selection: Binding(get: { time.whenOut }, set: { editor.plan.screenTime?.whenOut = $0 })) {
                    Text("Only listening").tag(KidsMode.listening)
                    Text("Nothing").tag(KidsMode.nothing)
                }
            }
        } header: {
            Text("Screen Time")
        } footer: {
            Text("Counts only films and series that play. Listening does not count.")
        }
    }

    private var awaySection: some View {
        @Bindable var editor = editor
        return Section {
            Picker("Away from home", selection: $editor.plan.away) {
                Text("As the week says").tag(KidsMode?.none)
                ForEach([KidsMode.ask, .listening, .nothing], id: \.self) { Text(KidsModeText.name($0)).tag(KidsMode?.some($0)) }
            }
        } footer: {
            Text("Away is anywhere but the home network. It needs no location.")
        }
    }

    private func musicSection(_ view: KidsPlanView) -> some View {
        @Bindable var editor = editor
        return Section {
            Toggle("Music and Audiobooks", isOn: $editor.plan.music)
            if editor.plan.music {
                ForEach(view.musicLibraries) { library in
                    Toggle(library.name, isOn: Binding(get: { editor.hears(library.id) }, set: { editor.setHears($0, source: library.id) }))
                }
            }
        } header: {
            Text("Music")
        }
    }

    // MARK: Lock to Lobby

    private func lockSection(_ view: KidsPlanView) -> some View {
        @Bindable var editor = editor
        return Section {
            Toggle("Lock this device to Lobby in kids mode", isOn: $editor.plan.lockToLobby)
                .accessibilityIdentifier("kidsPlan.lockToLobby")
            ForEach(view.lockDevices) { device in
                Toggle(
                    isOn: Binding(get: { device.wanted }, set: { on in Task { await editor.setLock(on, device: device.deviceId) } })
                ) {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        if device.status == .ready || device.status == .unsupported {
                            Text(KidsLockText.status(device))
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                        } else {
                            // Turned on, and it would not lock: the grown-ups need to see that.
                            Text(KidsLockText.status(device))
                                .font(.footnote)
                                .foregroundStyle(device.wanted ? Color.lobbyFailure : Color.secondary)
                        }
                    }
                }
                .disabled(device.status == .unsupported)
                .accessibilityIdentifier("kidsPlan.lock.\(device.deviceId)")
            }
        } header: {
            Text("Lock to Lobby")
        } footer: {
            Text("While \(name) is in kids mode, every other app on an iPhone or iPad is closed. For Grown-ups leaves kids mode and lifts it; back in kids mode it is on again. Each device is set up once, on that device: in Lobby's Settings, or after For Grown-ups on a device that is \(name)'s. A switch here acts at once, also from away.")
        }
    }

    // MARK: Places

    private var placesSection: some View {
        @Bindable var editor = editor
        return Section {
            ForEach(editor.plan.places) { place in
                Button {
                    editingPlace = place
                } label: {
                    LabeledContent(place.name, value: "\(KidsModeText.name(place.mode)) · \(KidsModeText.distance(place.radiusMeters))")
                }
            }
            if editor.plan.places.count < 10 {
                Button("Add a Place…", systemImage: AppSymbol.add) {
                    // Where it is comes from this device when the editor opens (PlaceEditor).
                    editingPlace = KidsPlace(
                        id: UUID().uuidString.lowercased(), name: "School", latitude: 0, longitude: 0, radiusMeters: 300, mode: .nothing)
                }
            }
            if !editor.plan.places.isEmpty {
                Picker("Where it cannot tell", selection: $editor.plan.whenPlaceUnknown) {
                    Text(KidsModeText.asSchedule).tag(KidsPlaceUnknown?.none)
                    ForEach(KidsPlaceUnknown.knownCases, id: \.self) { Text(KidsModeText.name($0)).tag(KidsPlaceUnknown?.some($0)) }
                }
            }
        } header: {
            Text("Places")
        } footer: {
            Text(
                "Lobby on \(name)'s device checks only whether it is inside these places. It never sends where it is, and keeps no history. Where it cannot tell, without Location or before it knows, the places do not count unless you choose otherwise."
            )
        }
    }
}

/// What the modes are called for grown-ups.
enum KidsModeText {
    static func name(_ mode: KidsMode) -> String {
        switch mode {
        case .everything: "Everything"
        case .ask: "Ask first"
        case .listening: "Only listening"
        case .nothing, .unknown: "Nothing"
        }
    }

    static let asSchedule = "As schedule"

    /// A place's mode: "as schedule" changes nothing there.
    static func name(_ mode: KidsPlaceMode) -> String {
        mode.mode.map { name($0) } ?? asSchedule
    }

    /// What holds where the device cannot tell, when a grown-up chose it.
    static func name(_ rule: KidsPlaceUnknown) -> String {
        rule.mode.map { name($0) } ?? "The strictest place"
    }

    static func override(_ mode: KidsMode) -> String {
        switch mode {
        case .everything: "Everything for…"
        case .ask: "Ask First for…"
        case .listening: "Only Listening for…"
        case .nothing, .unknown: "Nothing for…"
        }
    }

    static func symbol(_ mode: KidsMode) -> String {
        switch mode {
        case .everything: "play.tv"
        case .ask: "hand.raised"
        case .listening: "headphones"
        case .nothing, .unknown: "moon.zzz"
        }
    }

    static func days(_ days: [Int]) -> String {
        if days == [1, 2, 3, 4, 5] { return "Mon–Fri" }
        if days == Array(1...7) { return "Every day" }
        if days == [6, 7] { return "Weekends" }
        return days.map { KidsWeek.dayName($0) }.joined(separator: ", ")
    }

    static func distance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
    }
}

/// The week as seven bars of colour, one per day. A tap on a block opens it.
struct KidsWeekGrid: View {
    let plan: KidsPlan
    var open: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(KidsWeek.days, id: \.self) { day in
                HStack(spacing: 8) {
                    Text(KidsWeek.dayName(day)).font(.caption.monospaced()).frame(width: 36, alignment: .leading)
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(KidsWeek.segments(of: plan, day: day), id: \.self) { segment in
                                Rectangle()
                                    .fill(KidsGlance.color(segment.mode))
                                    .frame(width: geometry.size.width * CGFloat(segment.end - segment.start) / 1440)
                                    .onTapGesture { if let index = segment.blockIndex { open(index) } }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(height: 18)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(KidsWeek.dayName(day))
                .accessibilityValue(
                    KidsWeek.segments(of: plan, day: day)
                        .map { "\(KidsModeText.name($0.mode)) \(KidsWeek.time($0.start))–\(KidsWeek.time($0.end))" }
                        .joined(separator: ", "))
            }
        }
        .padding(.vertical, 4)
    }
}

/// The glance on the viewer list and the page's first line.
enum KidsGlance {
    static func line(_ now: KidsNow) -> String {
        let mode = now.at.waiting ? "Waiting for an answer" : KidsModeText.name(now.at.mode)
        guard let until = now.until else { return "Now: \(mode)" }
        return "Now: \(mode) until \(Date(millisecondsSince1970: until).formatted(date: .omitted, time: .shortened))"
    }

    static func color(_ mode: KidsMode) -> Color {
        switch mode {
        case .everything: .green.opacity(0.55)
        case .ask: .orange.opacity(0.7)
        case .listening: .blue.opacity(0.65)
        case .nothing, .unknown: .gray.opacity(0.6)
        }
    }
}

private struct BlockEdit: Identifiable {
    var index: Int?
    var block: KidsPlanBlock
    var id: String { index.map(String.init) ?? "new" }
}

/// One time of the week: which days, from and to, and what holds then.
private struct BlockEditor: View {
    let edit: BlockEdit
    let save: (KidsPlanBlock) -> Void
    let remove: () -> Void
    @State private var block: KidsPlanBlock
    @Environment(\.dismiss) private var dismiss

    init(edit: BlockEdit, save: @escaping (KidsPlanBlock) -> Void, remove: @escaping () -> Void) {
        self.edit = edit
        self.save = save
        self.remove = remove
        _block = State(initialValue: edit.block)
    }

    private func date(_ time: String) -> Date {
        Calendar.current.date(bySettingHour: KidsPlanResolver.minutes(time) / 60 % 24, minute: KidsPlanResolver.minutes(time) % 60, second: 0, of: Date()) ?? Date()
    }

    private func time(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return KidsWeek.time((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: Binding(get: { block.label ?? "" }, set: { block.label = $0.isEmpty ? nil : $0 }))
                Picker("What", selection: $block.mode) {
                    ForEach([KidsMode.everything, .ask, .listening, .nothing], id: \.self) { Text(KidsModeText.name($0)).tag($0) }
                }
                DatePicker("From", selection: Binding(get: { date(block.start) }, set: { block.start = time($0) }), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: Binding(get: { date(block.end) }, set: { block.end = time($0) }), displayedComponents: .hourAndMinute)
                Section("Days") {
                    ForEach(KidsWeek.days, id: \.self) { day in
                        Toggle(
                            KidsWeek.dayName(day),
                            isOn: Binding(
                                get: { block.days.contains(day) },
                                set: { on in block.days = on ? (block.days + [day]).sorted() : block.days.filter { $0 != day } }))
                    }
                }
                if edit.index != nil {
                    Button("Remove This Time", role: .destructive) {
                        remove()
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(edit.index == nil ? "New Time" : "Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(block)
                        dismiss()
                    }
                    .disabled(block.days.isEmpty || block.start == block.end)
                }
            }
        }
    }
}

/// A place on the map: its centre, how far around it, its name and what holds there.
private struct PlaceEditor: View {
    let isNew: Bool
    /// A place of the plan to look at while this device cannot say where it is.
    let nearby: KidsPlace?
    let save: (KidsPlace) -> Void
    let remove: () -> Void
    @State private var place: KidsPlace
    @State private var camera: MapCameraPosition
    @State private var search = ""
    /// A new place has no centre until this device says where it is, or the grown-up taps or finds one.
    @State private var hasCentre: Bool
    @State private var isLocating = false
    @State private var cannotLocate = false
    @State private var locator = PlaceLocator()
    @Environment(\.dismiss) private var dismiss

    init(place: KidsPlace, isNew: Bool, nearby: KidsPlace? = nil, save: @escaping (KidsPlace) -> Void, remove: @escaping () -> Void) {
        self.isNew = isNew
        self.nearby = nearby
        self.save = save
        self.remove = remove
        _place = State(initialValue: place)
        _hasCentre = State(initialValue: !isNew)
        // A new place: the map waits without a pin, at a place of the plan or the whole world.
        let shown = isNew ? nearby : place
        _camera = State(initialValue: shown.map { .region(Self.region(around: $0)) } ?? .region(MKCoordinateRegion(.world)))
    }

    private var centre: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude) }

    private static func region(around place: KidsPlace) -> MKCoordinateRegion {
        region(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), radius: place.radiusMeters)
    }

    private static func region(_ centre: CLLocationCoordinate2D, radius: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: centre, latitudinalMeters: radius * 4, longitudinalMeters: radius * 4)
    }

    private func move(to coordinate: CLLocationCoordinate2D) {
        place.latitude = coordinate.latitude
        place.longitude = coordinate.longitude
        hasCentre = true
        cannotLocate = false
        camera = .region(Self.region(coordinate, radius: place.radiusMeters))
    }

    /// Starts the place where this device is now.
    private func useMyLocation() async {
        isLocating = true
        defer { isLocating = false }
        if let here = await locator.locate() {
            move(to: here)
        } else {
            cannotLocate = true
        }
    }

    /// A new place: where this device is, else a place of the plan, else the country its
    /// region settings name. Never a city of its own.
    private func start() async {
        guard isNew else { return }
        if nearby == nil {
            Task {
                if let country = await PlaceLocator.homeRegion(), !hasCentre { camera = .region(country) }
            }
        }
        await useMyLocation()
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $place.name)
                Picker("What", selection: $place.mode) {
                    ForEach(KidsPlaceMode.knownCases, id: \.self) { Text(KidsModeText.name($0)).tag($0) }
                }
                HStack {
                    TextField("Find an address", text: $search)
                        .onSubmit { Task { await find() } }
                    Button("Find") { Task { await find() } }
                }
                Button("Use My Location", systemImage: "location") { Task { await useMyLocation() } }
                    .disabled(isLocating)
                    .accessibilityIdentifier("kidsPlace.useMyLocation")
                MapReader { proxy in
                    Map(position: $camera) {
                        if hasCentre {
                            MapCircle(center: centre, radius: place.radiusMeters)
                                .foregroundStyle(.orange.opacity(0.25))
                                .stroke(.orange, lineWidth: 2)
                            Marker(place.name, coordinate: centre)
                        }
                    }
                    .onTapGesture { point in
                        if let coordinate = proxy.convert(point, from: .local) {
                            place.latitude = coordinate.latitude
                            place.longitude = coordinate.longitude
                            hasCentre = true
                        }
                    }
                }
                .frame(height: 280)
                if isLocating && !hasCentre {
                    Text("Looking where this device is…").foregroundStyle(.secondary)
                } else if cannotLocate {
                    Text("This device cannot say where it is. Tap the map or find an address.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("Around it: \(KidsModeText.distance(place.radiusMeters))")
                    Slider(value: $place.radiusMeters, in: 100...10_000, step: 50)
                }
                if !isNew {
                    Button("Remove This Place", role: .destructive) {
                        remove()
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Place" : place.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(place)
                        dismiss()
                    }
                    .disabled(place.name.trimmingCharacters(in: .whitespaces).isEmpty || !hasCentre)
                }
            }
        }
        .task { await start() }
    }

    private func find() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = search
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        move(to: item.placemark.coordinate)
    }
}
