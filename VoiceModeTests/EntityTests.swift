import Foundation
import Testing
@testable import VoiceMode

struct EntityTests {
    private func matched(_ text: String, _ entities: [Entity]) -> [String] {
        let ns = text as NSString
        return EntityIndex(entities: entities).mentions(in: text).map { ns.substring(with: $0.range) }
    }

    @Test func indexMatchesWholeNamesAndPrefersLongestAlias() {
        let entities = [Entity(kind: .person, name: "Mensah", aliases: ["Dr. Mensah"]), Entity(kind: .person, name: "Lee")]
        let text = "Dr. Mensah nodded. Mensah’s team, Mensahs, Pin-Lee and Lee-ann left; Lee stayed."
        #expect(matched(text, entities) == ["Dr. Mensah", "Mensah", "Lee"])
        #expect(EntityIndex(entities: entities).mentions(in: "Dr. Mensah").first?.entity == 0)
    }

    @Test func candidatesKeepInventedNamesAndOrganisations() {
        let line = "“Stop,” said Overse. Overse looked at the crew. God, the Crew was tired, and Monday came. DeltFall sent nothing. "
        let text = String(repeating: line + "The crew slept while Overse watched. ", count: 10)
        let names = EntityExtractor.candidates(in: text).map(\.name)
        #expect(names.contains("Overse"))
        #expect(names.contains("DeltFall")) // never lowercase: a proper noun even without dialogue
        #expect(!names.contains("Crew")) // mostly lowercase: an ordinary word here
        #expect(!names.contains("God"))
        #expect(!names.contains("Monday"))
    }

    @Test func validationKeepsOnlySpellingsInTheTextAndKeepsKinds() {
        let text = "Lowen sat. Lowen stood. Low, he said. Low again. Pantem called. Pantem waited."
        let result = EntityExtractor.validated([
            Entity(kind: .person, name: "Lowen", aliases: ["Low", "Lowie"]),
            Entity(kind: .person, name: "Low"),
            Entity(kind: .person, name: "Nobody"),
            Entity(kind: .org, name: "Pantem"),
        ], in: text)
        #expect(result == [Entity(kind: .person, name: "Lowen", aliases: ["Low"]), Entity(kind: .org, name: "Pantem")])
    }

    @Test func entitiesLiveInPeopleAndOrgFolders() throws {
        #expect(Entity(kind: .person, name: "Dr. Pin-Lee").id == "people/dr-pin-lee")
        #expect(Entity(kind: .org, name: "GrayCris").id == "orgs/graycris")

        let folder = EntityFolder(key: "test-\(UUID().uuidString)")
        defer { folder.remove() }
        let org = Entity(kind: .org, name: "DeltFall")
        let card = EntityCard(summary: "A survey team.", through: ReadingPosition(chapter: 1, offset: 2))
        folder.saveIndex([org])
        folder.saveCard(card, for: org)
        folder.saveImage(Data([1, 2, 3]), for: org)
        #expect(folder.loadIndex() == [org])
        #expect(folder.loadCard(org) == card)
        #expect(folder.loadImage(org) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: folder.root.appending(path: "orgs/deltfall.json").path))
    }

    @Test func storyTextSkipsBackMatter() {
        let document = Document(title: "T", chapters: [
            Chapter(title: "One", text: "Story text."),
            Chapter(title: "Acknowledgments", text: "Thanks to Jill."),
        ])
        #expect(EntityExtractor.storyText(of: document) == "Story text.")
    }

    @Test func toolsCannotSeePastTheReader() {
        let document = Document(title: "T", chapters: [
            Chapter(title: "One", text: "Ann meets Bob."),
            Chapter(title: "Two", text: "Ann laughs. Later Bob dies."),
        ])
        let tools = BookTools(document: document, limit: ReadingPosition(chapter: 1, offset: 11))
        #expect(tools.grep("Ann").hasPrefix("2 matches"))
        #expect(tools.grep("dies") == "No matches.")
        #expect(tools.read(chapter: 1, offset: 0, length: 500) == "Ann laughs.")
        #expect(!tools.listChapters().contains("Three"))
    }

    @Test func cardParsingToleratesFencesAndDropsFutureMoments() {
        let content = """
        ```json
        {"summary": "A survey leader.", "role": "leader", "moments": [{"chapter": 0, "offset": 5, "note": "a"}, {"chapter": 2, "offset": 0, "note": "b"}]}
        ```
        """
        let card = EntityAgent.card(from: content, limit: ReadingPosition(chapter: 1, offset: 10))
        #expect(card?.summary == "A survey leader.")
        #expect(card?.moments.map(\.note) == ["a"])
        #expect(EntityAgent.card(from: "no json", limit: ReadingPosition(chapter: 0, offset: 0)) == nil)
    }

    @Test func imagePromptsDescribeWithoutNaming() {
        let card = EntityCard(summary: "s", role: "survey leader", traits: ["calm"], appearance: "woman in her forties, field jacket",
                              through: ReadingPosition(chapter: 0, offset: 0))
        let person = EntityStore.imagePrompt(for: .person, card: card)
        #expect(person.contains("character from a novel: woman in her forties, field jacket."))
        #expect(person.contains("real, modern photograph"))
        var plain = card
        plain.appearance = nil
        #expect(EntityStore.imagePrompt(for: .org, card: plain).contains("Emblem for a fictional organization in a novel: survey leader; calm"))
    }

    @Test func glamourOnlyForConfirmedAdultsAndDetailsAreAdded() {
        var card = EntityCard(summary: "s", appearance: "a tall man", through: ReadingPosition(chapter: 0, offset: 0))
        #expect(!EntityStore.imagePrompt(for: .person, card: card).contains("attractive"))
        card.isAdult = false
        #expect(!EntityStore.imagePrompt(for: .person, card: card).contains("attractive"))
        card.isAdult = true
        let prompt = EntityStore.imagePrompt(for: .person, card: card, style: .anime, details: "smiling ")
        #expect(prompt.contains("strikingly attractive adult"))
        #expect(prompt.contains("Also: smiling."))
        #expect(prompt.contains("anime"))
        #expect(!prompt.contains("photograph"))
    }

    @Test func adultFieldIsLenient() {
        let limit = ReadingPosition(chapter: 0, offset: 0)
        #expect(EntityAgent.card(from: #"{"summary": "x", "adult": "yes"}"#, limit: limit)?.isAdult == true)
        #expect(EntityAgent.card(from: #"{"summary": "x", "adult": false}"#, limit: limit)?.isAdult == false)
        #expect(EntityAgent.card(from: #"{"summary": "x", "adult": "unclear"}"#, limit: limit)?.isAdult == nil)
    }
}

struct ShortTextTests {
    @Test func shortTextsNeedFewerMentions() {
        let names = EntityExtractor.candidates(in: EntityExtractor.storyText(of: SampleContent.document)).map(\.name)
        #expect(names.contains("Bennet"))
        #expect(names.contains("Bingley"))
    }
}
