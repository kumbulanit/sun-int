package release

tuesday := {"service": "s", "budget_remaining": 0.4, "labels": [], "weekday": "Tuesday", "hour": 10}

test_budget_left_on_a_tuesday_passes if {
	count(deny) == 0 with input as tuesday
}

test_budget_gone_is_refused if {
	count(deny) == 1 with input as object.union(tuesday, {"budget_remaining": 0})
}

test_budget_gone_but_a_reliability_fix_passes if {
	count(deny) == 0 with input as object.union(tuesday, {"budget_remaining": -0.2, "labels": ["reliability-fix"]})
}

test_saturday_afternoon_is_refused if {
	count(deny) == 1 with input as object.union(tuesday, {"weekday": "Saturday", "hour": 14})
}

test_saturday_afternoon_rollback_passes if {
	count(deny) == 0 with input as object.union(tuesday, {"weekday": "Saturday", "hour": 14, "labels": ["rollback"]})
}

test_saturday_morning_passes if {
	count(deny) == 0 with input as object.union(tuesday, {"weekday": "Saturday", "hour": 9})
}
