{{- /*
The service's SLO alerts travel with the service. golden-path/slo/generate.py turns the
team's slo.yaml into slo-rules.yaml in their chart; this puts it in a ConfigMap with the
golden-path/slo-rules label, and the platform's Prometheus loads every such ConfigMap
in the cluster by itself. No SLO, no golden path: the install stops with how to fix it.
*/}}
{{- define "golden-path.sloRules" -}}
{{- $rules := .Files.Get "slo-rules.yaml" -}}
{{- if not $rules }}
{{- fail (printf "%s has no slo-rules.yaml. Every service on the golden path has an SLO: fill in charts/%s/slo.yaml, then run golden-path/slo/generate.sh charts/%s" (include "golden-path.name" .) (include "golden-path.name" .) (include "golden-path.name" .)) }}
{{- end -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "golden-path.name" . }}-slo-rules
  labels:
    {{- include "golden-path.labels" . | nindent 4 }}
    golden-path/slo-rules: "true"
data:
  {{ include "golden-path.name" . }}.rules.yaml: |
    {{- $rules | nindent 4 }}
{{- end }}
