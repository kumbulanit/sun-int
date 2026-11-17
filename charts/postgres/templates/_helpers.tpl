{{/* Labels on every object: what it is and what it belongs to. */}}
{{- define "postgres.labels" -}}
app.kubernetes.io/name: postgres
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: order-validation
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
