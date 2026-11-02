"""
Route post-processing: turn one continuous multi-floor PathResult into a
list of per-floor segments, each drawable onto that floor's SVG independently
(Step 6 of the original doc -- draw the route onto the currently-displayed
floor, then swap SVGs at the connector node).
"""
from __future__ import annotations
from dataclasses import dataclass
from .pathfinder import PathResult, PathStep


@dataclass
class FloorSegment:
    floor: int
    steps: list[PathStep]
    entry_connector: str | None   # node id the user arrives through, or None if this is the first segment
    exit_connector: str | None    # node id the user leaves through, or None if this is the last segment


def split_path_by_floor(result: PathResult) -> list[FloorSegment]:
    """Splits wherever the floor number changes. Note the connector edge
    itself connects two DISTINCT nodes (e.g. f0-stairs-nw -> f1-stairs-nw,
    not the same node reused) -- so the floor-A segment ends at f0-stairs-nw
    and the floor-B segment begins at f1-stairs-nw. Each segment is therefore
    independently drawable on its own floor's SVG, with no node reference
    that belongs to a different floor."""
    steps = result.steps
    if not steps:
        return []

    segments: list[FloorSegment] = []
    current: list[PathStep] = [steps[0]]

    for prev_step, step in zip(steps, steps[1:]):
        if step.floor != prev_step.floor:
            segments.append(FloorSegment(
                floor=prev_step.floor,
                steps=current,
                entry_connector=(segments[-1].exit_connector if segments else None),
                exit_connector=prev_step.node_id,
            ))
            current = [step]  # new segment starts at the arrival-side connector node
        else:
            current.append(step)

    segments.append(FloorSegment(
        floor=current[-1].floor,
        steps=current,
        entry_connector=(segments[-1].exit_connector if segments else None),
        exit_connector=None,
    ))
    return segments
