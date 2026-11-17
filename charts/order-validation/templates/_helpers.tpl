{{/* The image tag: the chart's appVersion unless one is given, and never "latest". */}}
{{- define "order-validation.tag" -}}
{{- $tag := toString (.Values.image.tag | default .Chart.AppVersion) -}}
{{- if eq $tag "latest" }}{{ fail "image.tag must be an exact version, not latest" }}{{ end -}}
{{ $tag }}
{{- end }}

{{- define "order-validation.labels" -}}
app.kubernetes.io/name: order-validation
app.kubernetes.io/version: {{ include "order-validation.tag" . | quote }}
app.kubernetes.io/part-of: order-validation
app.kubernetes.io/managed-by: {{ .Release.Service }}
team: storefront
{{- end }}

{{/* Locked down: no root, no extra Linux permissions, can't change its own files. */}}
{{- define "order-validation.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}
