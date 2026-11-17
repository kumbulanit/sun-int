# The container must run as a non-root user, and every base image must be pinned.
# Checked against each service's Dockerfile: conftest test <Dockerfile> --policy golden-path/pipeline/policy
package main

# Stage names ("FROM base AS runtime") are not images, so they need no tag.
stage_names := {lower(i.Value[2]) | some i in input; i.Cmd == "from"; count(i.Value) >= 3}

final_stage := max({i.Stage | some i in input})

users := [i.Value[0] | some i in input; i.Cmd == "user"; i.Stage == final_stage]

deny contains "Dockerfile: the final stage has no USER, so the container runs as root. Add USER 10001." if {
	count(users) == 0
}

deny contains msg if {
	user := users[count(users) - 1]
	user in {"root", "0"}
	msg := sprintf("Dockerfile: the container runs as %q. Use a numeric non-root user, e.g. USER 10001.", [user])
}

deny contains msg if {
	some i in input
	i.Cmd == "from"
	image := i.Value[0]
	not lower(image) in stage_names
	not contains(image, ":")
	msg := sprintf("Dockerfile: FROM %s has no tag, which means latest. Pin an exact version.", [image])
}

deny contains msg if {
	some i in input
	i.Cmd == "from"
	endswith(i.Value[0], ":latest")
	msg := sprintf("Dockerfile: FROM %s. Pin an exact version, not latest.", [i.Value[0]])
}
