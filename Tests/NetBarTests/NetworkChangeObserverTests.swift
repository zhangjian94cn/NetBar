import XCTest
@testable import NetBar

final class NetworkChangeObserverTests: XCTestCase {
    func testThunderboltBridgeMemberLinkChangeIsCritical() {
        let event = NetworkChangeEvent.classify(changedKeys: [
            "State:/Network/Interface/en6/Link"
        ])

        XCTAssertEqual(event, .physicalLink)
        XCTAssertTrue(
            NetworkChangeObserver.notificationPatterns.contains { pattern in
                "State:/Network/Interface/en6/Link".range(
                    of: pattern,
                    options: .regularExpression
                ) != nil
            },
            "任意雷雳口映射到的 bridge 成员都必须触发事件检查"
        )
    }

    func testActiveMiniPhysicalLinkChangeGetsImmediateVisibleReaction() {
        let reaction = NetworkChangeEvent.physicalLink.reaction(
            preference: .miniPreferred,
            activeMode: .macMiniGateway
        )

        XCTAssertEqual(reaction.delay, 0.1)
        XCTAssertEqual(reaction.message, "检测到雷雳链路变化，正在确认并回退 Wi-Fi…")
    }
}
