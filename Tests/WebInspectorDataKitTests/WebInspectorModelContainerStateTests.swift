import Testing
@testable import WebInspectorDataKit

@Test
func modelContainerConfigurationNormalizesCSSAndUsesSessionIdentity() {
    let first = WebInspectorModelContainer(
        configuration: .init(domains: [.css])
    )
    let second = WebInspectorModelContainer(
        configuration: .init(domains: [.css])
    )

    #expect(first.configuration.domains == [.dom, .css])
    #expect(first == first)
    #expect(first != second)
    #expect(first.state == .detached)
}

@Test
func modelContainerStateSequenceKeepsOnlyTheNewestUnconsumedValue() async {
    let publication = WebInspectorModelContainerStatePublication()
    var updates = publication.subscribe().makeAsyncIterator()

    #expect(await updates.next() == .detached)
    publication.publish(.attaching)
    publication.publish(.attached)
    publication.publish(.detaching)

    #expect(await updates.next() == .detaching)
}

@Test
func modelContainerStateSequenceDeliversClosedExactlyOnceThenFinishes() async {
    let publication = WebInspectorModelContainerStatePublication()
    var existing = publication.subscribe().makeAsyncIterator()

    #expect(await existing.next() == .detached)
    let firstRevision = publication.publish(.attaching)
    #expect(publication.publish(.attaching) == firstRevision)
    #expect(publication.finish() == firstRevision + 1)
    #expect(publication.finish() == firstRevision + 1)

    #expect(await existing.next() == .closed)
    #expect(await existing.next() == nil)
    #expect(await existing.next() == nil)

    var late = publication.subscribe().makeAsyncIterator()
    #expect(await late.next() == .closed)
    #expect(await late.next() == nil)
}

@Test
func modelContainerStateMailboxRejectsDeliveryInversionByRevision() async {
    let mailbox = WebInspectorModelContainerStateMailbox(
        revision: 10,
        state: .detached,
        finishesAfterPendingState: false
    )
    mailbox.offer(
        revision: 12,
        state: .attached,
        finishesAfterState: false
    )
    mailbox.offer(
        revision: 11,
        state: .attaching,
        finishesAfterState: false
    )
    mailbox.claimIterator()

    #expect(await mailbox.next() == .attached)
}

@Test
func modelContainerStateIteratorCancellationIsTerminal() async {
    let mailbox = WebInspectorModelContainerStateMailbox(
        revision: 0,
        state: .detached,
        finishesAfterPendingState: false
    )
    mailbox.claimIterator()
    #expect(await mailbox.next() == .detached)

    let next = Task { await mailbox.next() }
    next.cancel()
    #expect(await next.value == nil)
    #expect(await mailbox.next() == nil)
}
