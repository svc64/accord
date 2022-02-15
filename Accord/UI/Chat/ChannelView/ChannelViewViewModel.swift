//
//  ChannelViewViewModel.swift
//  Accord
//
//  Created by evelyn on 2021-10-22.
//

import AppKit
import Combine
import Foundation
import SwiftUI

final class ChannelViewViewModel: ObservableObject {
    #if DEBUG
        internal static let developingOffline: Bool = false
    #endif

    @Published var messages = [Message]()
    @Published var nicks: [String: String] = [:]
    @Published var roles: [String: String] = [:]
    @Published var avatars: [String: String] = [:]
    @Published var pronouns: [String: String] = [:]
    var cancellable = Set<AnyCancellable>()

    var guildID: String
    var channelID: String

    init(channelID: String, guildID: String) {
        self.channelID = channelID
        self.guildID = guildID
        guard wss != nil else { return }
        messageFetchQueue.async {
            self.guildID == "@me" ? try? wss.subscribeToDM(channelID) : try? wss.subscribe(to: guildID)
            MentionSender.shared.removeMentions(server: guildID)
            // fetch messages
        }
        self.getMessages(channelID: channelID, guildID: guildID)
        subscribe()
    }

    func subscribe() {
        wss.messageSubject
            .receive(on: webSocketQueue)
            .sink { [weak self] msg, channelID, _ in
                guard channelID == self?.channelID else { return }
                guard let message = try? JSONDecoder().decode(GatewayMessage.self, from: msg).d else { return }
                if self?.guildID != "@me", !(self?.roles.keys.contains(message.author?.id ?? "") ?? false) {
                    self?.loadUser(for: message.author?.id)
                }
                if let firstMessage = self?.messages.first {
                    message.sameAuthor = firstMessage.author?.id == message.author?.id
                }
                DispatchQueue.main.async {
                    if let count = self?.messages.count, count == 50 {
                        self?.messages.removeLast()
                    }
                    guard let author = message.author else { return }
                    Storage.usernames[author.id] = author.username
                    withAnimation {
                        self?.messages.insert(message, at: 0)
                    }
                }
            }
            .store(in: &cancellable)
        wss.memberChunkSubject
            .receive(on: webSocketQueue)
            .sink { [weak self] msg in
                guard let chunk = try? JSONDecoder().decode(GuildMemberChunkResponse.self, from: msg), let users = chunk.d?.members else { return }
                guard let self = self else { return }
                let allUsers: [GuildMember] = users.compactMap { $0 }
                for person in allUsers {
                    DispatchQueue.main.async {
                        wss.cachedMemberRequest["\(self.guildID)$\(person.user.id)"] = person
                    }
                    if let nickname = person.nick {
                        DispatchQueue.main.async {
                            self.nicks[person.user.id] = nickname
                        }
                    }
                    if let avatar = person.avatar {
                        self.avatars[person.user.id] = avatar
                    }
                    if let roles = person.roles {
                        var rolesTemp: [Int : String] = [:]
                        for role in roles {
                            if let roleColor = roleColors[role]?.1 {
                                rolesTemp[roleColor] = role
                            }
                        }
                        let temp: [String] = (rolesTemp.compactMap { $0.value }).reversed()
                        if !(temp.isEmpty) {
                            DispatchQueue.main.async {
                                self.roles[person.user.id] = temp[0]
                            }
                        }
                    }
                }
            }
            .store(in: &cancellable)
        wss.deleteSubject
            .receive(on: webSocketQueue)
            .sink { [weak self] msg, channelID in
                guard channelID == self?.channelID else { return }
                let messageMap = self?.messages.enumerated().compactMap { index, element in
                    [element.id: index]
                }.reduce(into: [:]) { result, next in
                    result.merge(next) { _, rhs in rhs }
                }
                guard let gatewayMessage = try? JSONDecoder().decode(GatewayDeletedMessage.self, from: msg) else { return }
                guard let message = gatewayMessage.d else { return }
                guard let index = messageMap?[message.id] else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        let i: Int = index
                        self?.messages.remove(at: i)
                    }
                }
            }
            .store(in: &cancellable)
        wss.editSubject
            .receive(on: webSocketQueue)
            .sink { [weak self] msg, channelID in
                // Received a message from backend
                guard channelID == self?.channelID else { return }
                guard let message = try? JSONDecoder().decode(GatewayMessage.self, from: msg).d else { return }
                let messageMap = self?.messages.enumerated().compactMap { index, element in
                    [element.id: index]
                }.reduce(into: [:]) { result, next in
                    result.merge(next) { _, rhs in rhs }
                }
                guard let index = messageMap?[message.id] else { return }
                DispatchQueue.main.async {
                    self?.messages[index] = message
                }
            }
            .store(in: &cancellable)
    }

    func ack(channelID: String, guildID: String) {
        guard let last = messages.first?.id else { return }
        Request.ping(url: URL(string: "\(rootURL)/channels/\(channelID)/messages/\(last)/ack"), headers: Headers(
            userAgent: discordUserAgent,
            token: AccordCoreVars.token,
            bodyObject: ["token": NSNull()], // I don't understand why this is needed, but it wasn't when I first implemented ack...
            type: .POST,
            discordHeaders: true,
            referer: "https://discord.com/channels/\(guildID)/\(channelID)",
            json: true
        ))
    }

    func getMessages(channelID: String, guildID: String) {
        RequestPublisher.fetch([Message].self, url: URL(string: "\(rootURL)/channels/\(channelID)/messages?limit=50"), headers: Headers(
            userAgent: discordUserAgent,
            token: AccordCoreVars.token,
            type: .GET,
            discordHeaders: true,
            referer: "https://discord.com/channels/\(guildID)/\(channelID)"
        ))
        .subscribe(on: messageFetchQueue)
        .receive(on: messageFetchQueue)
        .map { output -> [Message] in
            output.enumerated().compactMap { index, element -> Message in
                guard element != output.last else { return element }
                element.sameAuthor = output[index + 1].author?.id == element.author?.id
                return element
            }
        }
        .receive(on: DispatchQueue.main)
        .sink(receiveCompletion: { completion in
            switch completion {
            case .finished: break
            case let .failure(error):
                print(error)
                MentionSender.shared.deselect()
            }
        }) { [weak self] messages in
            self?.messages = messages
            messageFetchQueue.async {
                guildID == "@me" ? self?.fakeNicksObject() : self?.performSecondStageLoad()
                self?.loadPronouns()
                self?.ack(channelID: channelID, guildID: guildID)
                self?.cacheUsernames()
            }
        }
        .store(in: &cancellable)
    }

    func cacheUsernames() {
        messages.forEach { message in
            guard let author = message.author else { return }
            Storage.usernames[author.id] = author.username
        }
    }

    func loadUser(for id: String?) {
        guard let id = id else { return }
        guard let person = wss.cachedMemberRequest["\(guildID)$\(id)"] else {
            try? wss.getMembers(ids: [id], guild: guildID)
            return
        }
        let nickname = person.nick ?? person.user.username
        DispatchQueue.main.async {
            self.nicks[person.user.id] = nickname
        }
        if let avatar = person.avatar {
            avatars[person.user.id] = avatar
        }
        if let roles = person.roles {
            var rolesTemp: [Int : String] = [:]
            for role in roles {
                if let roleColor = roleColors[role]?.1 {
                    rolesTemp[roleColor] = role
                }
            }
            let temp: [String] = rolesTemp.compactMap { $0.value }.reversed()
            if !(temp.isEmpty) {
                DispatchQueue.main.async {
                    self.roles[person.user.id] = temp[0]
                }
            }
        }
    }

    func fakeNicksObject() {
        guard guildID == "@me" else { return }
        let _nicks: [String: String] = messages.compactMap { [$0.author?.id ?? "": $0.author?.username ?? ""] }
            .flatMap { $0 }
            .reduce([String: String]()) { dict, tuple in
                var nextDict = dict
                nextDict.updateValue(tuple.1, forKey: tuple.0)
                return nextDict
            }
        DispatchQueue.main.async {
            self.nicks = _nicks
        }
    }

    func loadPronouns() {
        guard AccordCoreVars.pronounDB else { return }
        RequestPublisher.fetch([String: String].self, url: URL(string: "https://pronoundb.org/api/v1/lookup-bulk"), headers: Headers(
            bodyObject: [
                "platform": "discord",
                "ids": messages.compactMap { $0.author?.id }.joined(separator: ","),
            ],
            type: .GET
        ))
        .replaceError(with: [:])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] value in
            self?.pronouns = value.mapValues {
                pronounDBFormed(pronoun: $0)
            }
        }
        .store(in: &cancellable)
    }

    func getCachedMemberChunk() {
        let allUserIDs = messages.compactMap { $0.author?.id }
            .removingDuplicates()
        for person in allUserIDs.compactMap({ wss.cachedMemberRequest["\(guildID)$\($0)"] }) {
            let nickname = person.nick ?? person.user.username
            DispatchQueue.main.async {
                self.nicks[person.user.id] = nickname
            }
            if let avatar = person.avatar {
                avatars[person.user.id] = avatar
            }
            if let roles = person.roles {
                print(person.user.username, roles)
                for role in roles.sorted(by: { lhs, rhs -> Bool in
                    guard let lhs = roleColors[lhs]?.1, let rhs = roleColors[rhs]?.1 else { return false }
                    return lhs < rhs
                }) {
                    DispatchQueue.main.async {
                        self.roles[person.user.id] = role
                    }
                }
            }
        }
    }

    func performSecondStageLoad() {
        var allUserIDs: [String] = Array(NSOrderedSet(array: messages.compactMap { $0.author?.id })) as! [String]
        // getCachedMemberChunk()
        for (index, item) in allUserIDs.enumerated {
            if Array(wss.cachedMemberRequest.keys).contains("\(guildID)$\(item)"), [Int](allUserIDs.indices).contains(index) {
                allUserIDs.remove(at: index)
            }
        }
        if !(allUserIDs.isEmpty) {
            try? wss.getMembers(ids: allUserIDs, guild: guildID)
        }
    }

    func loadMoreMessages() {
        RequestPublisher.fetch([Message].self, url: URL(string: "\(rootURL)/channels/\(channelID)/messages?before=\(messages.last?.id ?? "")&limit=50"), headers: Headers(
            userAgent: discordUserAgent,
            token: AccordCoreVars.token,
            type: .GET,
            discordHeaders: true,
            referer: "https://discord.com/channels/\(guildID)/\(channelID)"
        ))
        .sink(receiveCompletion: { _ in

        }) { [weak self] msg in
            let messages: [Message] = msg.enumerated().compactMap { index, element -> Message in
                guard element != msg.last else { return element }
                element.sameAuthor = msg[index + 1].author?.id == element.author?.id
                return element
            }
            self?.messages.append(contentsOf: messages)
        }
        .store(in: &cancellable)
    }

    deinit {
        print("Closing \(channelID)")
    }
}

extension Array where Array.Element: Hashable {
    func unique() -> some Collection {
        Array(Set(self))
    }
}

extension Array {
    var enumerated: EnumeratedSequence<[Element]> {
        self.enumerated()
    }
}
