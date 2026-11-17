{{- define "golden-path.deployment" -}}
{{- $telemetry := .Values.telemetry | default dict -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "golden-path.name" . }}
  labels:
    {{- include "golden-path.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicas | default 2 }}   # at least 2, so one pod can restart without an outage
  selector:
    matchLabels:
      {{- include "golden-path.selector" . | nindent 6 }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0   # never below full capacity during a deploy...
      maxSurge: 1         # ...one new pod at a time; it must be ready before an old one goes
  template:
    metadata:
      labels:
        {{- include "golden-path.labels" . | nindent 8 }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      automountServiceAccountToken: false     # services never talk to the Kubernetes API
      terminationGracePeriodSeconds: 20       # the 5 s pre-stop wait plus up to ~10 s for the app's own shutdown
      # Security is the platform's rule, not a team setting: no value can loosen it.
      securityContext:
        runAsNonRoot: true                    # the image must run as a numeric non-root user
        seccompProfile:
          type: RuntimeDefault
      {{- with .Values.waitFor }}
      # Helm starts everything at once. These wait until each listed dependency answers
      # before the app starts. List only what the app truly can't start without.
      initContainers:
        {{- range . }}
        - name: wait-for-{{ .name }}
          image: busybox:1.37.0
          command: [sh, -c, 'until nc -z -w 2 {{ .host }} {{ .port }}; do echo "waiting for {{ .name }} at {{ .host }}:{{ .port }}"; sleep 2; done']
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 32Mi}
          securityContext:
            runAsUser: 65534                  # nobody: busybox would otherwise run as root
            {{- include "golden-path.containerSecurity" $ | nindent 12 }}
        {{- end }}
      {{- end }}
      containers:
        - name: app
          image: {{ include "golden-path.image" . }}
          imagePullPolicy: {{ (.Values.image).pullPolicy | default "IfNotPresent" }}
          ports:
            - name: http
              containerPort: {{ .Values.port | default 8080 }}
          env:
            {{- /* On unless switched off. (Not `default true`: Helm's default treats false as empty.) */}}
            {{- if ne (toString $telemetry.enabled) "false" }}
            # Telemetry, the same for every service (golden-path/telemetry/STANDARD.md).
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: OTEL_SERVICE_NAME
              value: {{ include "golden-path.name" . }}
            - name: OTEL_RESOURCE_ATTRIBUTES      # service.instance.id: each pod's numbers stay separate
              value: "service.instance.id=$(POD_NAME),service.version={{ include "golden-path.tag" . }},deployment.environment.name={{ $telemetry.environment | default "local" }},team={{ .Values.team }}"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT   # the platform's collector, where the cost controls are
              value: {{ $telemetry.endpoint | default "http://otel-collector.platform:4318" | quote }}
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: http/protobuf
            - name: OTEL_METRIC_EXPORT_INTERVAL   # how often metrics are sent: freshness vs cost
              value: {{ $telemetry.exportIntervalMs | default 15000 | quote }}
            - name: OTEL_LOGS_EXPORTER
              value: none                         # logs go to stdout as JSON, not through the collector
            {{- else }}
            - name: OTEL_SDK_DISABLED             # telemetry switched off: nothing is sent anywhere
              value: "true"
            {{- end }}
            # The service's own settings.
            {{- range $name, $value := .Values.env }}
            - name: {{ $name }}
              value: {{ $value | quote }}
            {{- end }}
            {{- range $name, $from := .Values.secretEnv }}
            - name: {{ $name }}
              valueFrom:
                secretKeyRef:
                  name: {{ $from.secret }}
                  key: {{ $from.key }}
            {{- end }}
          readinessProbe:                     # ~10 s failing: stop sending it traffic (it is not restarted)
            httpGet:
              path: {{ (.Values.probes).readiness | default "/readyz" }}
              port: http
            periodSeconds: 5
            failureThreshold: 2
          livenessProbe:                      # ~30 s failing: the pod is broken, restart it
            httpGet:
              path: {{ (.Values.probes).liveness | default "/healthz" }}
              port: http
            periodSeconds: 10
            failureThreshold: 3
          resources:
            {{- toYaml (required "resources is required: requests (what the cluster reserves and you pay for) and a memory limit" .Values.resources) | nindent 12 }}
          securityContext:
            {{- include "golden-path.containerSecurity" . | nindent 12 }}
          lifecycle:
            preStop:
              # Wait 5 s before shutting down, so the cluster has stopped sending traffic
              # here first. Without it, a few requests fail on every deploy.
              sleep:
                seconds: 5
{{- end }}
