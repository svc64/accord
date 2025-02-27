//
//  GatewayStructure.swift
//  GatewayStructure
//
//  Created by evelyn on 2021-08-27.
//

import Foundation

struct GatewayStructure: Decodable {
    var t: String?
    var d: GatewayD
    var s: Int
    var op: Int
}

struct GatewayD: Decodable {
    var v: Int?
    var user_settings: Settings?
    var user: User
    var session_id: String
    var read_state: ReadState?
    @IgnoreFailure
    var guilds: [Guild]
    var friend_suggestion_count: Int?
    var country_code: String
}

final class Relationship: Codable {
    var user_id: String
    var nick: String?
    var type: Int?
    var id: String
}
