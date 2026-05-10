import XCTest
@testable import NetBar

final class KeychainHelperTests: XCTestCase {

    private let testKey = "com.zjah.NetBar.test_key_\(UUID().uuidString)"

    override func tearDown() {
        super.tearDown()
        KeychainHelper.delete(key: testKey)
    }

    func testSaveAndLoadString() {
        KeychainHelper.save(key: testKey, value: "test_secret_123")
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, "test_secret_123")
    }

    func testLoadNonexistentKey() {
        let loaded = KeychainHelper.loadString(key: "nonexistent_key_\(UUID().uuidString)")
        XCTAssertNil(loaded)
    }

    func testUpsertOverwritesValue() {
        KeychainHelper.save(key: testKey, value: "first_value")
        KeychainHelper.save(key: testKey, value: "second_value")
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, "second_value")
    }

    func testDeleteRemovesValue() {
        KeychainHelper.save(key: testKey, value: "to_delete")
        let deleted = KeychainHelper.delete(key: testKey)
        XCTAssertTrue(deleted)
        XCTAssertNil(KeychainHelper.loadString(key: testKey))
    }

    func testSaveAndLoadEmptyString() {
        KeychainHelper.save(key: testKey, value: "")
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, "")
    }

    func testSaveAndLoadUnicodeString() {
        let unicode = "密码🔑测试"
        KeychainHelper.save(key: testKey, value: unicode)
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, unicode)
    }
}
