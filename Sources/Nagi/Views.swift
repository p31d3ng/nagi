import SwiftUI
import JournalCore
struct ContentView:View {
    @EnvironmentObject var j:Journal
    @State private var section="Timeline"
    @State private var editing:Segment?
    @State private var deleteCandidate:Session?
    let accent=Color(red:0.17,green:0.42,blue:0.43)
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:24) {
                HStack {Image(systemName:"waveform.circle.fill").font(.largeTitle).foregroundStyle(accent);Text("Nagi").font(.title2.weight(.semibold))}.padding(.top,18)
                Text("YOUR LOCAL VOICE JOURNAL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(["Timeline","Devices","Models","Voice profile","Dictionary","Storage"],id:\.self){name in Button {section=name} label:{Label(name,systemImage:icon(name)).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(section==name ? accent.opacity(0.13):.clear,in:RoundedRectangle(cornerRadius:10))}.buttonStyle(.plain)}
                Spacer()
                Label("Only on this Mac",systemImage:"lock.shield").font(.callout).foregroundStyle(accent)
                Text("Audio: 48 hours\nTranscripts: until you delete them or reach your chosen cap.").font(.caption).foregroundStyle(.secondary)
            }.padding(20).navigationSplitViewColumnWidth(220)
        } detail:{
            VStack(spacing:0) {
                statusBar.padding(24).background(.background)
                Divider()
                if section=="Timeline" {timeline}
                else {ScrollView {settingsSection.padding(32).frame(maxWidth:800,alignment:.leading)}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)}
            }.background(Color(nsColor:.windowBackgroundColor))
        }
        .tint(accent)
        .alert("Needs attention",isPresented:Binding(get:{j.error != nil},set:{if !$0{j.error=nil}})){Button("OK"){j.error=nil}} message:{Text(j.error ?? "")}
        .alert("Your selected input is connected",isPresented:$j.connectionPrompt){Button("Start recording"){j.start()};Button("Later",role:.cancel){}} message:{Text("Start a new conversation with this input? Recording begins only after you choose Start.")}
        .confirmationDialog("Delete this conversation and its saved audio?",isPresented:Binding(get:{deleteCandidate != nil},set:{if !$0{deleteCandidate=nil}})){Button("Delete conversation",role:.destructive){if let s=deleteCandidate{j.delete(s)};deleteCandidate=nil}} message:{Text("This also deletes its original and corrected transcript versions.")}
        .sheet(item:$editing){segment in EditTranscript(segment:segment).environmentObject(j)}
    }
    func icon(_ name:String)->String {switch name{case "Devices":return "mic";case "Models":return "cpu";case "Voice profile":return "person.crop.circle";case "Dictionary":return "text.book.closed";case "Storage":return "internaldrive";default:return "clock"}}
    var statusBar:some View {
        HStack(spacing:16){
            Circle().fill(j.recording ? .red:accent).frame(width:12,height:12)
            VStack(alignment:.leading,spacing:5){Text(j.status).font(.headline);Text(j.processing).font(.caption).foregroundStyle(.secondary)}
            Spacer()
            if j.recording && j.level<0.0008 && j.elapsed>8 {Text("Input is quiet · check TX / receiver").font(.caption).foregroundStyle(.orange)}
            if j.recording {Text(String(format:"%02d:%02d",j.elapsed/60,j.elapsed%60)).monospacedDigit();ProgressView(value:j.level).frame(width:90).accessibilityLabel("Input level")}
            Button(j.recording ? "Stop & save":"Start recording",systemImage:j.recording ? "stop.fill":"record.circle"){j.recording ? j.stop():j.start()}.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
    var timeline:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {VStack(alignment:.leading,spacing:4){Text("Your conversations").font(.largeTitle.weight(.semibold));Text("Meetings, plans, and passing thoughts — easy to find again.").foregroundStyle(.secondary)};Spacer();Button("Import audio",systemImage:"square.and.arrow.down"){j.importAudio()}.disabled(j.recording)}
            HStack {Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("Search transcript words across your timeline",text:$j.query).textFieldStyle(.plain).onChange(of:j.query){_,_ in j.refresh()};Picker("Speaker",selection:$j.speakerFilter){Text("All speakers").tag("");ForEach(Array(Set(((try? j.store.segments(session:j.selected)) ?? []).map(\.speaker))).sorted(),id:\.self){Text($0).tag($0)}}.frame(width:140).onChange(of:j.speakerFilter){_,_ in j.refresh()};Picker("Language",selection:$j.languageFilter){Text("All languages").tag("");ForEach(["en · model assumption","ja · script estimate","zh / ja uncertain","mixed / uncertain","uncertain"],id:\.self){Text($0).tag($0)}}.frame(width:150).onChange(of:j.languageFilter){_,_ in j.refresh()};Button("Clear"){j.query="";j.speakerFilter="";j.languageFilter="";j.refresh()}}.padding(13).background(.background,in:RoundedRectangle(cornerRadius:12))
            HStack(alignment:.top,spacing:20){
                ScrollView {LazyVStack(spacing:10){ForEach(j.sessions){session in Button {j.selected=session.id;j.refresh()} label:{VStack(alignment:.leading,spacing:9){HStack {Image(systemName:"bubble.left.and.bubble.right").foregroundStyle(accent);Text(Date(timeIntervalSince1970:session.started).formatted(date:.abbreviated,time:.shortened)).font(.caption);Spacer()};Text(session.title).font(.headline).lineLimit(2);HStack{Text(session.status.capitalized).font(.caption).foregroundStyle(.secondary);Spacer();Text(session.model=="unified" ? "EN":"MULTI").font(.caption2.weight(.bold)).foregroundStyle(accent)}}.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(j.selected==session.id ? accent.opacity(0.13):Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14))}.buttonStyle(.plain)}}}.frame(width:260)
                ScrollView {
                    VStack(alignment:.leading,spacing:16){
                        if let session=j.sessions.first(where:{$0.id==j.selected}) {
                            HStack {Text(session.title).font(.title2.weight(.semibold));Spacer();Button(role:.destructive){deleteCandidate=session}label:{Image(systemName:"trash")}.disabled(j.recording)}
                            Text(session.device).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            DisclosureGroup("Recording details"){Text(j.store.setting("metadata-"+session.id)+"\n"+j.store.setting("format-"+session.id)).font(.caption.monospaced()).textSelection(.enabled)}
                            if !session.note.isEmpty {Label(session.note,systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)}
                            Text(speakerSummary).font(.caption).foregroundStyle(accent)
                            let chunks=(try? j.store.chunks(session:session.id)) ?? []
                            if let first=chunks.first {Text("Audio expires \(Date(timeIntervalSince1970:first.captured+172800).formatted()). Deletion runs when the app is awake; expired audio cannot play.").font(.caption).foregroundStyle(.secondary)}
                            if chunks.contains(where:{$0.status=="failed" || $0.status=="needs_speakers"}) {Button("Retry failed processing",systemImage:"arrow.clockwise"){do{try j.processor.retry()}catch{j.error=error.localizedDescription}};ForEach(chunks.filter{$0.status=="failed" || $0.status=="needs_speakers"},id:\.id){chunk in Text((try? j.store.exec("SELECT error FROM chunks WHERE id=?",[chunk.id]).first?["error"]) ?? "Processing failed").font(.caption).foregroundStyle(.orange)}}
                        }
                        if j.segments.isEmpty {ContentUnavailableView(!j.query.isEmpty ? "No matching words":j.sessions.isEmpty ? "A quiet place for your conversations":j.selected==nil ? "Choose a conversation":"No transcript yet",systemImage:"waveform",description:Text(!j.query.isEmpty ? "Try another word or clear the speaker and language filters.":j.sessions.isEmpty ? "Choose your receiver in Devices, then start recording. You can also import a local audio file.":j.selected==nil ? "Select a recent conversation to review its transcript and playback.":"Audio chunks are durable. Processing status and recovery options appear above; silence has no transcript."))}
                        ForEach(j.segments){segment in
                            VStack(alignment:.leading,spacing:10){HStack {Text(segment.speaker).font(.subheadline.weight(.semibold)).foregroundStyle(accent);Text(segment.language).font(.caption).foregroundStyle(.secondary);Spacer();Button {j.play(segment)}label:{Label(time(segment.offset),systemImage:"play.circle")}.buttonStyle(.plain);Button {editing=segment}label:{Image(systemName:"pencil")}.buttonStyle(.plain)};Text(segment.corrected).font(.system(size:16)).lineSpacing(5).textSelection(.enabled);if segment.raw != segment.corrected {DisclosureGroup("Original transcript"){Text(segment.raw).font(.callout).textSelection(.enabled)}.font(.caption);Button("Undo correction"){j.undo(segment)}.font(.caption)}}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:14))
                        }
                        if j.playing {Button("Stop playback",systemImage:"stop.circle"){j.stopPlayback()}}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }.padding(28)
    }
    var speakerSummary:String {let speakers=Set(j.segments.map(\.speaker).filter{!$0.hasPrefix("Unknown")});return speakers.isEmpty ? "Speaker count uncertain · labels need analysis or review":"Estimated \(speakers.count) speaker(s) · review labels, especially overlap and distant voices"}
    func time(_ offset:Double)->String {String(format:"%02d:%02d",Int(offset)/60,Int(offset)%60)}
    @ViewBuilder var settingsSection:some View {
        VStack(alignment:.leading,spacing:22){Text(section).font(.largeTitle.weight(.semibold))
            switch section {
            case "Devices":
                Text("Select the receiver you want to record. We remember its stable UID and never fall back to another input.").foregroundStyle(.secondary)
                Picker("Input",selection:$j.inputUID){Text("Choose an input").tag("");ForEach(j.devices){Text($0.name).tag($0.id)};if !j.inputUID.isEmpty,!j.devices.contains(where:{$0.id==j.inputUID}){Text("Selected input disconnected").tag(j.inputUID)}}.disabled(j.recording)
                Text(j.inputUID.isEmpty ? "No input selected":j.inputUID).font(.caption.monospaced()).textSelection(.enabled)
                Label("Receiver unplug stops and saves. Wireless transmitter loss may look like silence; silence is not proof of disconnection.",systemImage:"antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                Toggle("Prevent idle system sleep while recording",isOn:$j.keepAwake).disabled(j.recording)
                Text("Closing the window or locking the screen keeps the menu-bar app running. System sleep stops recording and marks a gap; start again after wake.").font(.callout).foregroundStyle(.secondary)
            case "Models":
                Text("Choose manually before each session. Models and audio remain on this Mac. ASR and speaker analysis run sequentially.").foregroundStyle(.secondary)
                Picker("Speech-to-text model",selection:$j.model){ForEach(Models.all){Text($0.name).tag($0.id)}}.disabled(j.recording)
                ForEach(Models.all){model in VStack(alignment:.leading,spacing:8){Text(model.name).font(.headline);Text(model.languages);Text(model.revision).font(.caption.monospaced()).textSelection(.enabled);Label(FileManager.default.fileExists(atPath:j.project.appendingPathComponent("Models/"+model.filename).path) ? "Installed locally":"Missing — see setup instructions",systemImage:"internaldrive").font(.caption)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:14))}
                Text("English uses the exact Handy Unified model, not TDT v3. Language tags are conservative script estimates or model assumptions. Preferred words are review hints; no guaranteed decode-time bias.").font(.callout).foregroundStyle(.secondary)
            case "Voice profile":
                Label(j.profileReady ? "Local voice profile enrolled":"No voice profile yet",systemImage:"person.crop.circle.badge.checkmark").font(.title2)
                Text("Sit alone in a quiet room. Use your selected receiver. Read the passage below naturally for 20 seconds. Recording starts only when you press Enroll; you can stop at any time.").foregroundStyle(.secondary)
                Text("“Today I am planning my next meeting. I want to remember the ideas we share, the decisions we make, and the questions I still have. This is my journal, and I can review or change every speaker label.”").font(.title3).padding(20).background(.background,in:RoundedRectangle(cornerRadius:14))
                Button(j.enrollment ? "Stop enrollment":"Enroll my voice (20 seconds)"){j.enrollment ? j.stop(note:"Enrollment stopped early"):j.start(enroll:true)}.buttonStyle(.borderedProminent).disabled(j.recording && !j.enrollment)
                Button("Delete local voice profile",role:.destructive){j.forgetProfile()}.disabled(!j.profileReady)
                Text("Only Community-1 embeddings are matched. Conservative similarity and margin thresholds may leave Unknown labels. Synthetic voice tests cannot establish accuracy on real people. One wearable mic may miss distant speech and overlap.").font(.callout).foregroundStyle(.secondary)
            case "Dictionary":
                Text("Preferred words (review hints)").font(.headline)
                TextField("DJI, Nagi, Kyoto…",text:$j.preferredWords).textFieldStyle(.roundedBorder)
                Text("Exact replacements — one ‘from => to’ rule per line").font(.headline)
                TextEditor(text:$j.rulesText).font(.system(.body,design:.monospaced)).frame(height:200).padding(8).background(.background,in:RoundedRectangle(cornerRadius:10))
                Text("Rules apply after ASR to future jobs. They are case-sensitive and may replace substrings. Raw text and previous corrections are retained; use Undo or edit in the timeline.").font(.callout).foregroundStyle(.secondary)
            default:
                Text("Audio and every derived audio copy expire 48 hours from capture. Original sample rate and channels are retained in losslessly gzip-compressed CAF chunks. The local data directory is excluded from backups where macOS supports it.").foregroundStyle(.secondary)
                Toggle("Cap transcript text and correction history at 500 MB",isOn:$j.capEnabled)
                Text("At the cap, the oldest whole conversations and their audio are evicted. This counts UTF-8 transcript text and correction history, not SQLite index/file overhead. Turn the cap off to keep transcripts until you delete them.").font(.callout).foregroundStyle(.secondary)
                Text(j.store.root.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("Run expiry cleanup now"){j.stopPlayback();j.processor.maintenance()}
                Text("While the app or Mac is off, deletion cannot run. On startup and wake expired files are removed; playback is disabled once expiry passes. No uploads, account, or cloud endpoint is present.").font(.callout).foregroundStyle(.secondary)
            }
            if section != "Voice profile" {Button("Save settings"){j.saveSettings()}.buttonStyle(.borderedProminent).disabled(j.recording)}
        }
    }
}
struct PreferencesView:View {var body:some View{ContentView()}}
struct EditTranscript:View {
    @EnvironmentObject var j:Journal
    @Environment(\.dismiss) var dismiss
    let segment:Segment
    @State private var text=""
    @State private var speaker="Unknown"
    var body:some View {VStack(alignment:.leading,spacing:20){Text("Review transcript").font(.title2.weight(.semibold));TextEditor(text:$text).frame(height:180);TextField("Speaker label (Me / Speaker 2 / Unknown)",text:$speaker).textFieldStyle(.roundedBorder);DisclosureGroup("Raw ASR text"){Text(segment.raw).textSelection(.enabled)};HStack{Button("Cancel"){dismiss()};Spacer();Button("Save correction"){j.edit(segment,text:text,speaker:speaker);dismiss()}.buttonStyle(.borderedProminent)}}.padding(28).frame(width:600).onAppear{text=segment.corrected;speaker=segment.speaker}}

}
