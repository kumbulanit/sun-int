{{- define "platform.labels" -}}
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
team: platform
{{- end }}

{{/* The same locked-down settings the golden path gives every service. */}}
{{- define "platform.podSecurity" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "platform.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}
