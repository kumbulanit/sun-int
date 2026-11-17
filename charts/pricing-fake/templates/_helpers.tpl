{{/* The image: the chart's appVersion unless a tag is given, and never "latest". */}}
{{- define "pricing-fake.tag" -}}
{{- $tag := toString (.Values.image.tag | default .Chart.AppVersion) -}}
{{- if eq $tag "latest" }}{{ fail "image.tag must be an exact version, not latest" }}{{ end -}}
{{ $tag }}
{{- end }}

{{- define "pricing-fake.labels" -}}
app.kubernetes.io/name: pricing-fake
app.kubernetes.io/version: {{ include "pricing-fake.tag" . | quote }}
app.kubernetes.io/part-of: order-validation
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
