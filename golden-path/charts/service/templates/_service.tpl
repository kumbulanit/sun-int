{{- /* A stable address inside the cluster: http://<name>:<port>. */}}
{{- define "golden-path.svc" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "golden-path.name" . }}
  labels:
    {{- include "golden-path.labels" . | nindent 4 }}
spec:
  type: ClusterIP   # inside the cluster only; from a laptop: kubectl port-forward
  selector:
    {{- include "golden-path.selector" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.port | default 8080 }}
      targetPort: http
{{- end }}

{{- /* Node drains and cluster upgrades may stop only one pod at a time, so the
       service never goes to zero. Only with 2 or more pods: with one, it would block drains. */}}
{{- define "golden-path.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "golden-path.name" . }}
  labels:
    {{- include "golden-path.labels" . | nindent 4 }}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      {{- include "golden-path.selector" . | nindent 6 }}
{{- end }}
