{{/*
Shared pieces and guard rails. A mistake fails at install time with a clear message,
never as a broken pod. The service's name is its chart's name.
*/}}

{{- define "golden-path.name" -}}
{{- .Chart.Name -}}
{{- end }}

{{/* The image tag: the chart's appVersion unless one is given. Never "latest". */}}
{{- define "golden-path.tag" -}}
{{- $tag := toString ((.Values.image).tag | default .Chart.AppVersion) -}}
{{- if or (eq $tag "") (eq $tag "latest") }}{{ fail "image.tag must be an exact version (or leave it empty to use appVersion), never latest" }}{{ end -}}
{{ $tag }}
{{- end }}

{{- define "golden-path.image" -}}
{{- required "image.repository is required, e.g. ghcr.io/myorg/my-service" (.Values.image).repository }}:{{ include "golden-path.tag" . }}
{{- end }}

{{/* Labels on every object: what it is, which version, and which team owns it (cost reports, alert routing). */}}
{{- define "golden-path.labels" -}}
app.kubernetes.io/name: {{ include "golden-path.name" . }}
app.kubernetes.io/version: {{ include "golden-path.tag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
team: {{ required "team is required: the owning team, e.g. storefront" .Values.team }}
{{- end }}

{{/* Picks this service's pods. Must never change after the first install. */}}
{{- define "golden-path.selector" -}}
app.kubernetes.io/name: {{ include "golden-path.name" . }}
{{- end }}

{{/* Locked down: no privilege escalation, no Linux capabilities, can't change its own files. */}}
{{- define "golden-path.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{/* Everything a service gets, in one include. A team's chart has one template:
       {{ include "golden-path.service" . }}                                       */}}
{{- define "golden-path.service" -}}
{{ include "golden-path.deployment" . }}
---
{{ include "golden-path.svc" . }}
{{- if gt (int (.Values.replicas | default 2)) 1 }}
---
{{ include "golden-path.pdb" . }}
{{- end }}
---
{{ include "golden-path.sloRules" . }}
{{- end }}
