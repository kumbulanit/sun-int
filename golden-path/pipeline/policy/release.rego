# The release rules (golden-path/README.md, "When your error budget runs out"), checked before every production deploy.
# Input, from golden-path/pipeline/release-facts.sh:
#   {"service": "...", "budget_remaining": 0.42, "labels": ["rollback"], "weekday": "Saturday", "hour": 14}
package release

exceptions := {"reliability-fix", "rollback", "budget-exception"}

deny contains msg if {
	input.budget_remaining <= 0
	count({label | some label in input.labels; label in exceptions}) == 0
	msg := sprintf("%s has used its whole error budget: only reliability fixes and rollbacks ship. Label the run reliability-fix, rollback, or budget-exception (signed off by the product owner).", [input.service])
}

deny contains "Saturday 13:00-17:00 is the flash-sale deploy freeze: only rollbacks. Label the run rollback if this is one." if {
	input.weekday == "Saturday"
	input.hour >= 13
	input.hour < 17
	not "rollback" in input.labels
}
