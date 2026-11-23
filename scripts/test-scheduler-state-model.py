#!/usr/bin/env python3
"""Explore late verification requests and results across two assignments.

One task, owner, executor and reviewer. Assignment dispatch may be delivered
or uncertain. Recovery observes that prior work has stopped or been fenced.
Transport is a fixture. At most one check result is awaiting publication.
The clock can advance past its lease. Crashes, external effects and approval
after review are outside this model. Run from the marketplace source checkout.
"""

from collections import deque
from dataclasses import dataclass, replace
import hashlib
from importlib import import_module
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


ContractFixture = import_module("test-task-contract").ContractFixture
ROOT = Path(__file__).resolve().parents[1]
MAX_GENERATIONS = 2


@dataclass(frozen=True)
class State:
    phase: str = "ready"
    generation: int = 0
    receipt_generation: int = 0  # No receipt yet.
    pending_result: int = 0  # A verification that began and can still return.


@dataclass(frozen=True)
class Event:
    action: str
    generation: int


def successors(state, omit_guard):
    if state.phase == "ready" and state.generation < MAX_GENERATIONS:
        generation = state.generation + 1
        for outcome in ("assigned", "uncertain"):
            yield Event(outcome, generation), State(outcome, generation, pending_result=state.pending_result)
    elif state.phase == "assigned":
        yield Event("block", state.generation), replace(state, phase="blocked")
        if not state.pending_result:
            for origin in range(1, state.generation + 1):
                if origin == state.generation or omit_guard == "request":
                    yield Event("start-check", origin), replace(state, phase="verifying", pending_result=origin)
    elif state.phase == "verifying":
        yield Event("expire", state.generation), replace(state, phase="expired")
    elif state.phase in ("uncertain", "blocked", "expired"):
        yield Event("reconcile", state.generation), State("ready", state.generation, pending_result=state.pending_result)

    if state.pending_result:
        # Time passing alone does not invalidate a reservation. Reconciliation
        # changes its revision. A late publisher cannot claim a newer task.
        holds_reservation = state.phase in ("verifying", "expired") and state.pending_result == state.generation
        if holds_reservation or omit_guard == "publication":
            yield Event("publish", state.pending_result), replace(
                state, phase="assigned", receipt_generation=state.pending_result, pending_result=0)
        else:
            yield Event("refused-result", state.pending_result), replace(state, pending_result=0)


def explore(omit_guard=None):
    """Breadth-first search makes the first counterexample a shortest one."""
    initial = State()
    pending = deque([(initial, ())])
    seen = {initial}
    edges = 0
    while pending:
        state, trace = pending.popleft()
        for event, following in successors(state, omit_guard):
            edges += 1
            path = (*trace, event)
            # The property is identical for the original and mutated model.
            wrong_request = event.action == "start-check" and event.generation != state.generation
            if wrong_request or following.receipt_generation not in (0, following.generation):
                return seen, edges, path
            if following not in seen:
                seen.add(following)
                pending.append((following, path))
    return seen, edges, ()


class ModelCheck(unittest.TestCase):
    def test_bounded_property_and_mutation_control(self):
        states, edges, witness = explore()
        self.assertFalse(witness, witness)
        for phase in ("assigned", "uncertain", "blocked", "ready"):
            self.assertIn(State(phase, MAX_GENERATIONS), states)
        self.assertIn(State("assigned", MAX_GENERATIONS, MAX_GENERATIONS), states)
        print(f"Bound: {MAX_GENERATIONS} generations, {len(states)} reachable states, "
              f"{edges} enabled transitions.")
        for guard in ("request", "publication"):
            with self.subTest(guard=guard):
                _, _, witness = explore(omit_guard=guard)
                self.assertTrue(witness, f"The missing {guard} guard should violate the property")
                print(f"Counterexample without {guard} guard:",
                      " -> ".join(f"{e.action}({e.generation})" for e in witness))


class CodexReplay(ContractFixture):
    def setUp(self):
        super().setUp()
        self.owner = self.mod.Store('T1', 'owner')
        self.store.actor = 'executor'

    def apply_task_event(self, event):
        if event.action in ("assigned", "uncertain"):
            self.owner.dispatch = lambda *args: event.action == "assigned"
            result = self.owner.assign('executor', 'Verify the fixture change')
            self.assertEqual(result["state"], event.action)
            self.assertEqual(result["generation"], event.generation)
        elif event.action == "block":
            self.assertEqual(self.store.transition("block", event.generation, "Work stopped")["state"], "blocked")
        elif event.action == "reconcile":
            self.assertEqual(self.owner.reconcile(event.generation, "Fixture worker is fenced")["state"], "reconciled")
        else:
            self.fail(f"Unsupported model event: {event}")

    def check_current_receipt(self):
        current = self.read()["contract"]["generation"]
        valid = self.store.verify(current, self.mod.hashed(self.spec))
        self.assertEqual(valid["state"], "passed")
        receipt_path = Path(valid["receipt"])
        self.assertEqual(self.read()["contract"]["receipt"]["name"], receipt_path.name)
        self.assertEqual(json.loads(receipt_path.read_text())["generation"], current)

    def test_late_request_on_real_store(self):
        _, _, witness = explore(omit_guard="request")
        self.assertTrue(witness)
        for event in witness[:-1]:
            self.apply_task_event(event)
        late = witness[-1]
        current = self.read()["contract"]["generation"]
        self.assertEqual(late.action, "start-check")
        self.assertLess(late.generation, current)
        self.assertEqual(self.read()["status"], "assigned")
        before = self.path.read_bytes()
        handoffs = self.store.artifacts
        had_handoffs = handoffs.exists()
        artifacts = set(handoffs.glob("*"))
        with self.assertRaisesRegex(ValueError, "obsolete assignment generation"):
            self.store.verify(late.generation, self.mod.hashed(self.spec))
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(handoffs.exists(), had_handoffs)
        self.assertEqual(set(handoffs.glob("*")), artifacts)
        self.check_current_receipt()

    def test_late_completed_check_on_real_store(self):
        _, _, witness = explore(omit_guard="publication")
        start = next(i for i, event in enumerate(witness) if event.action == "start-check")
        for event in witness[:start]:
            self.apply_task_event(event)
        first = witness[start].generation
        self.assertEqual(witness[-1], Event("publish", first))
        self.assertEqual(witness[start+1].action, "expire")
        publish = self.store.finish
        before_publication = []

        def interleave_owner_recovery(revision, update):
            # Store.verify has executed the real check and written its receipt.
            # Pause only the publication call, then resume it with its own token.
            pending, = self.store.artifacts.glob("receipt-*")
            receipt = json.loads(pending.read_text())
            self.assertEqual((receipt["generation"], receipt["result"]), (first, "passed"))
            self.assertEqual(receipt["checks"][0]["exit_code"], 0)
            contract = self.read()["contract"]
            self.assertEqual(contract["phase"], "verifying")
            expiry = contract["reservation"]["expires_at"]
            with patch.object(self.mod.time, "time", return_value=expiry - 1):
                with self.assertRaisesRegex(ValueError, "reservation has not expired"):
                    self.owner.reconcile(first, "The fixture worker is fenced at publication")
            with patch.object(self.mod.time, "time", return_value=expiry + 1):
                for event in witness[start+2:-1]:
                    self.apply_task_event(event)
            current = self.read()["contract"]
            self.assertGreater(current["generation"], first)
            self.assertNotIn("receipt", current)
            before_publication.append(self.path.read_bytes())
            return publish(revision, update)

        with patch.object(self.store, "finish", side_effect=interleave_owner_recovery):
            with self.assertRaisesRegex(ValueError, "late result rejected: reservation changed"):
                self.store.verify(first, self.mod.hashed(self.spec))
        self.assertEqual(before_publication, [self.path.read_bytes()])
        self.check_current_receipt()
        digest = hashlib.sha256(self.module_path.read_bytes()).hexdigest()
        print(f"{self.provider}: late publication refused; current receipt passed. "
              f"task-contract.py sha256={digest}")


class ClaudeReplay(CodexReplay):
    provider = "plugins"


if __name__ == "__main__":
    revision = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                              text=True, capture_output=True)
    print("Checkout:", revision.stdout.strip() or "unversioned")
    for name in ("test-scheduler-state-model.py", "test-task-contract.py"):
        print(f"{name} sha256={hashlib.sha256((ROOT / 'scripts' / name).read_bytes()).hexdigest()}")
    unittest.main()
