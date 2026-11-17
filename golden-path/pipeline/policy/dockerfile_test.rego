package main

base := {"Cmd": "from", "Value": ["python:3.12.16-slim-trixie", "AS", "base"], "Stage": 0}

runtime := {"Cmd": "from", "Value": ["base", "AS", "runtime"], "Stage": 1}

test_pinned_and_non_root_passes if {
	count(deny) == 0 with input as [base, runtime, {"Cmd": "user", "Value": ["10001"], "Stage": 1}]
}

test_no_user_is_refused if {
	count(deny) == 1 with input as [base, runtime]
}

test_root_user_is_refused if {
	count(deny) == 1 with input as [base, runtime, {"Cmd": "user", "Value": ["root"], "Stage": 1}]
}

test_latest_is_refused if {
	count(deny) == 1 with input as [{"Cmd": "from", "Value": ["python:latest"], "Stage": 0}, {"Cmd": "user", "Value": ["10001"], "Stage": 0}]
}

test_untagged_image_is_refused if {
	count(deny) == 1 with input as [{"Cmd": "from", "Value": ["python"], "Stage": 0}, {"Cmd": "user", "Value": ["10001"], "Stage": 0}]
}
