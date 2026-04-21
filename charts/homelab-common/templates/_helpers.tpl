{{/*
Expand the name of the chart.
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "common.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "common.labels" -}}
helm.sh/chart: {{ include "common.chart" . }}
{{ include "common.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Standard deployment strategy
*/}}
{{- define "common.deploymentStrategy" -}}
{{- if .Values.deployment.strategy }}
{{- .Values.deployment.strategy }}
{{- else }}
Recreate
{{- end }}
{{- end }}

{{/*
Standard container port (for backward compatibility)
*/}}
{{- define "common.containerPort" -}}
{{- if .Values.container.ports }}
{{- $primaryPort := first .Values.container.ports }}
{{- $primaryPort.port }}
{{- else if .Values.container.port }}
{{- .Values.container.port }}
{{- else }}
80
{{- end }}
{{- end }}

{{/*
Container ports list
*/}}
{{- define "common.containerPorts" -}}
{{- if .Values.container.ports }}
{{- range .Values.container.ports }}
- name: {{ .name }}
  containerPort: {{ .port }}
  protocol: {{ .protocol | default "TCP" }}
{{- end }}
{{- else if .Values.container.port }}
- name: http
  containerPort: {{ .Values.container.port }}
  protocol: TCP
{{- else }}
- name: http
  containerPort: 80
  protocol: TCP
{{- end }}
{{- end }}

{{/*
Standard service port (for backward compatibility)
*/}}
{{- define "common.servicePort" -}}
{{- if .Values.service.ports }}
{{- $primaryService := first .Values.service.ports }}
{{- $primaryService.port }}
{{- else if .Values.service.port }}
{{- .Values.service.port }}
{{- else }}
80
{{- end }}
{{- end }}

{{/*
Service ports list
*/}}
{{- define "common.servicePorts" -}}
{{- if .Values.service.ports }}
{{- range .Values.service.ports }}
- port: {{ .port }}
  targetPort: {{ .targetPort | default .port }}
  protocol: {{ .protocol | default "TCP" }}
  name: {{ .name }}
{{- end }}
{{- else if .Values.service.port }}
- port: {{ .Values.service.port }}
  targetPort: {{ include "common.containerPort" . }}
  protocol: TCP
  name: {{ .Values.service.portName | default "http" }}
{{- else }}
- port: 80
  targetPort: {{ include "common.containerPort" . }}
  protocol: TCP
  name: {{ .Values.service.portName | default "http" }}
{{- end }}
{{- end }}

{{/*
Standard health probe
*/}}
{{- define "common.healthProbe" -}}
{{- if .Values.container.healthProbe }}
{{- $probePort := .Values.container.healthProbe.port | default (include "common.containerPort" .) }}
{{- if eq .Values.container.healthProbe.type "httpGet" }}
httpGet:
  path: {{ .Values.container.healthProbe.path | default "/" }}
  port: {{ $probePort }}
{{- else if eq .Values.container.healthProbe.type "tcpSocket" }}
tcpSocket:
  port: {{ $probePort }}
{{- else if eq .Values.container.healthProbe.type "exec" }}
exec:
  command:
    {{- toYaml .Values.container.healthProbe.command | nindent 4 }}
{{- end }}
{{- if .Values.container.healthProbe.initialDelaySeconds }}
initialDelaySeconds: {{ .Values.container.healthProbe.initialDelaySeconds }}
{{- end }}
{{- if .Values.container.healthProbe.periodSeconds }}
periodSeconds: {{ .Values.container.healthProbe.periodSeconds }}
{{- end }}
{{- if .Values.container.healthProbe.timeoutSeconds }}
timeoutSeconds: {{ .Values.container.healthProbe.timeoutSeconds }}
{{- end }}
{{- if .Values.container.healthProbe.failureThreshold }}
failureThreshold: {{ .Values.container.healthProbe.failureThreshold }}
{{- end }}
{{- else }}
tcpSocket:
  port: {{ include "common.containerPort" . }}
{{- end }}
{{- end }}

{{/*
Full domain name
*/}}
{{- define "common.domain" -}}
{{ .Values.subdomain }}.{{ .Values.globals.domain }}
{{- end }}

{{/*
Full URL
*/}}
{{- define "common.url" -}}
https://{{ include "common.domain" . }}
{{- end }}

{{/*
Standard volume mounts
*/}}
{{- define "common.volumeMounts" -}}
{{- range .Values.volumes }}
- name: {{ .name }}
  mountPath: {{ .mountPath }}
{{- if .subPath }}
  subPath: {{ .subPath }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Standard volumes
*/}}
{{- define "common.volumes" -}}
{{- range .Values.volumes }}
- name: {{ .name }}
  {{- if .persistentVolumeClaim }}
  persistentVolumeClaim:
    {{- if or (eq .persistentVolumeClaim "config") (eq .persistentVolumeClaim "metadata") (eq .persistentVolumeClaim "data") }}
    claimName: {{ $.Release.Name }}-{{ .persistentVolumeClaim }}
    {{- else }}
    claimName: {{ .persistentVolumeClaim }}
    {{- end }}
  {{- else if .configMap }}
  configMap:
    name: {{ .configMap | replace "{release}" $.Release.Name | replace "{namespace}" $.Release.Namespace | replace "{fullname}" (include "common.fullname" $) }}
  {{- else if .secret }}
  secret:
    secretName: {{ .secret | replace "{release}" $.Release.Name | replace "{namespace}" $.Release.Namespace | replace "{fullname}" (include "common.fullname" $) }}
  {{- else if .emptyDir }}
  emptyDir: {}
  {{- else if .hostPath }}
  hostPath:
    path: {{ .hostPath }}
    {{- if .hostPathType }}
    type: {{ .hostPathType }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Standard environment variables
*/}}
{{- define "common.env" -}}
{{- if .Values.env }}
{{- range $key, $value := .Values.env }}
- name: {{ $key }}
  {{- if kindIs "map" $value }}
  {{- if $value.valueFrom }}
  valueFrom:
    {{- if $value.valueFrom.secretKeyRef }}
    secretKeyRef:
      name: {{ $value.valueFrom.secretKeyRef.name | replace "{release}" $.Release.Name | replace "{namespace}" $.Release.Namespace | replace "{fullname}" (include "common.fullname" $) }}
      key: {{ $value.valueFrom.secretKeyRef.key }}
    {{- else if $value.valueFrom.configMapKeyRef }}
    configMapKeyRef:
      name: {{ $value.valueFrom.configMapKeyRef.name | replace "{release}" $.Release.Name | replace "{namespace}" $.Release.Namespace | replace "{fullname}" (include "common.fullname" $) }}
      key: {{ $value.valueFrom.configMapKeyRef.key }}
    {{- end }}
  {{- else if $value.value }}
  value: {{ $value.value | replace "{release}" $.Release.Name | replace "{namespace}" $.Release.Namespace | replace "{fullname}" (include "common.fullname" $) | replace "{subdomain}" $.Values.subdomain | replace "{domain}" $.Values.globals.domain | replace "{timezone}" $.Values.globals.timezone | quote }}
  {{- end }}
  {{- else }}
  value: {{ $value | replace "{release}" $.Release.Name | replace "{namespace}" $.Release.Namespace | replace "{fullname}" (include "common.fullname" $) | replace "{subdomain}" $.Values.subdomain | replace "{domain}" $.Values.globals.domain | replace "{timezone}" $.Values.globals.timezone | quote }}
  {{- end }}
{{- end }}
{{- end }}
{{- if .Values.globals.timezone }}
- name: TZ
  value: {{ .Values.globals.timezone | quote }}
{{- end }}
{{- end }}

{{/*
VirtualService gateway list for public gateway
*/}}
{{- define "common.virtualServiceGatewaysPublic" -}}
- {{ .Values.globals.istio.gateways.public | quote }}
- mesh
{{- end }}

{{/*
VirtualService gateway list for private gateway
*/}}
{{- define "common.virtualServiceGatewaysPrivate" -}}
- {{ .Values.globals.istio.gateways.private | quote }}
- mesh
{{- end }}

{{/*
DNS configuration for pod spec
*/}}
{{- define "common.dnsConfig" -}}
{{- if .Values.deployment.dns }}
{{- if .Values.deployment.dns.nameservers }}
dnsPolicy: {{ .Values.deployment.dns.policy | default "None" }}
dnsConfig:
  nameservers:
{{- range .Values.deployment.dns.nameservers }}
    - {{ . | quote }}
{{- end }}
{{- if .Values.deployment.dns.searches }}
  searches:
{{- range .Values.deployment.dns.searches }}
    - {{ . | quote }}
{{- end }}
{{- end }}
{{- if .Values.deployment.dns.options }}
  options:
{{- range .Values.deployment.dns.options }}
    - {{ toYaml . | nindent 6 }}
{{- end }}
{{- end }}
{{- end }}
{{- else if .Values.deployment.dnsPolicy }}
dnsPolicy: {{ .Values.deployment.dnsPolicy }}
{{- end }}
{{- end }}

{{/*
Full Deployment resource
*/}}
{{- define "common.deployment" -}}
{{- if .Values.deployment }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  strategy:
    type: {{ include "common.deploymentStrategy" . }}
  replicas: {{ .Values.deployment.replicas | default 1 }}
  {{- if hasKey .Values.deployment "revisionHistoryLimit" }}
  revisionHistoryLimit: {{ .Values.deployment.revisionHistoryLimit }}
  {{- else }}
  revisionHistoryLimit: 2
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      {{- if .Values.deployment.podAnnotations }}
      annotations:
        {{- toYaml .Values.deployment.podAnnotations | nindent 8 }}
      {{- end }}
      labels:
        {{- include "common.selectorLabels" . | nindent 8 }}
    spec:
      {{- if .Values.deployment.serviceAccountName }}
      serviceAccountName: {{ .Values.deployment.serviceAccountName | replace "{release}" .Release.Name | replace "{fullname}" (include "common.fullname" .) }}
      {{- end }}
      {{- if .Values.deployment.hostNetwork }}
      hostNetwork: {{ .Values.deployment.hostNetwork }}
      {{- end }}
      {{- if .Values.deployment.hostAliases }}
      hostAliases:
        {{- toYaml .Values.deployment.hostAliases | nindent 8 }}
      {{- end }}
      {{- include "common.dnsConfig" . | nindent 6 }}
      {{- if .Values.initContainers }}
      initContainers:
        {{- $initContainers := toYaml .Values.initContainers -}}
        {{- $initContainers = $initContainers | replace "{release}" .Release.Name -}}
        {{- $initContainers = $initContainers | replace "{namespace}" .Release.Namespace -}}
        {{- $initContainers = $initContainers | replace "{fullname}" (include "common.fullname" .) -}}
        {{- if .Values.subdomain -}}
        {{- $initContainers = $initContainers | replace "{subdomain}" .Values.subdomain -}}
        {{- end -}}
        {{- if and .Values.globals .Values.globals.domain -}}
        {{- $initContainers = $initContainers | replace "{domain}" .Values.globals.domain -}}
        {{- end -}}
        {{- if and .Values.globals .Values.globals.timezone -}}
        {{- $initContainers = $initContainers | replace "{timezone}" .Values.globals.timezone -}}
        {{- end -}}
        {{- $initContainers | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
          {{- if .Values.command }}
          command:
            {{- $command := toYaml .Values.command -}}
            {{- $command = $command | replace "{release}" .Release.Name -}}
            {{- $command = $command | replace "{namespace}" .Release.Namespace -}}
            {{- $command = $command | replace "{fullname}" (include "common.fullname" .) -}}
            {{- if .Values.subdomain -}}
            {{- $command = $command | replace "{subdomain}" .Values.subdomain -}}
            {{- end -}}
            {{- if and .Values.globals .Values.globals.domain -}}
            {{- $command = $command | replace "{domain}" .Values.globals.domain -}}
            {{- end -}}
            {{- if and .Values.globals .Values.globals.timezone -}}
            {{- $command = $command | replace "{timezone}" .Values.globals.timezone -}}
            {{- end -}}
            {{- $command | nindent 12 }}
          {{- end }}
          {{- if .Values.args }}
          args:
            {{- $args := toYaml .Values.args -}}
            {{- $args = $args | replace "{release}" .Release.Name -}}
            {{- $args = $args | replace "{namespace}" .Release.Namespace -}}
            {{- $args = $args | replace "{fullname}" (include "common.fullname" .) -}}
            {{- if .Values.subdomain -}}
            {{- $args = $args | replace "{subdomain}" .Values.subdomain -}}
            {{- end -}}
            {{- if and .Values.globals .Values.globals.domain -}}
            {{- $args = $args | replace "{domain}" .Values.globals.domain -}}
            {{- end -}}
            {{- if and .Values.globals .Values.globals.timezone -}}
            {{- $args = $args | replace "{timezone}" .Values.globals.timezone -}}
            {{- end -}}
            {{- $args | nindent 12 }}
          {{- end }}
          ports:
{{ include "common.containerPorts" . | indent 12 }}
          {{- if .Values.container.healthProbe }}
          livenessProbe:
{{ include "common.healthProbe" . | indent 12 }}
          readinessProbe:
{{ include "common.healthProbe" . | indent 12 }}
          {{- end }}
          {{- if .Values.container.resources }}
          resources:
            {{- toYaml .Values.container.resources | nindent 12 }}
          {{- end }}
          {{- if .Values.container.securityContext }}
          securityContext:
            {{- toYaml .Values.container.securityContext | nindent 12 }}
          {{- end }}
          {{- if .Values.volumes }}
          volumeMounts:
{{ include "common.volumeMounts" . | indent 12 }}
          {{- end }}
          {{- if or .Values.env .Values.globals.timezone }}
          env:
{{ include "common.env" . | indent 12 }}
          {{- end }}
      {{- if .Values.volumes }}
      volumes:
        {{- include "common.volumes" . | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}

{{/*
Full ServiceAccount resource
*/}}
{{- define "common.serviceAccount" -}}
{{- if .Values.serviceAccount }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ if .Values.serviceAccount.name }}{{ .Values.serviceAccount.name }}{{ else }}{{ include "common.fullname" . }}{{ end }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
{{- if .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml .Values.serviceAccount.annotations | nindent 4 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Full Service resource(s) - supports multiple services
*/}}
{{- define "common.service" -}}
{{- if .Values.service }}
{{- if .Values.service.ports }}
{{- $firstPort := index .Values.service.ports 0 }}
{{- range $index, $port := .Values.service.ports }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ if $port.serviceName }}{{ include "common.fullname" $ }}-{{ $port.serviceName }}{{ else }}{{ include "common.fullname" $ }}{{ if and (gt $index 0) }}-{{ $port.name }}{{ end }}{{ end }}
  labels:
    {{- include "common.labels" $ | nindent 4 }}
spec:
  type: {{ $port.type | default $.Values.service.type | default "ClusterIP" }}
  ports:
    - port: {{ $port.port }}
      targetPort: {{ $port.targetPort | default $port.port }}
      protocol: {{ $port.protocol | default "TCP" }}
      name: {{ $port.name }}
  selector:
    {{- include "common.selectorLabels" $ | nindent 4 }}
{{- end }}
{{- else }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type | default "ClusterIP" }}
  ports:
{{ include "common.servicePorts" . | indent 4 }}
  selector:
    {{- include "common.selectorLabels" . | nindent 4 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Full PVC resources
*/}}
{{- define "common.pvc" -}}
{{- if .Values.persistentVolumeClaims }}
{{- range .Values.persistentVolumeClaims }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $.Release.Name }}-{{ .name }}
  annotations:
    longhorn.io/description: "{{ $.Release.Namespace }}/{{ $.Release.Name }}"
    argocd.argoproj.io/sync-options: Delete=false
  labels:
    {{- include "common.labels" $ | nindent 4 }}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: {{ .size }}
  {{- if .storageClassName }}
  storageClassName: {{ .storageClassName }}
  {{- else if $.Values.globals.storageClassName }}
  storageClassName: {{ $.Values.globals.storageClassName }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Full VirtualService resources
*/}}
{{- define "common.virtualService" -}}
{{- if and .Values.virtualService.enabled .Values.subdomain (hasKey .Values.globals "domain") (ne .Values.globals.domain "") }}
{{- if and .Values.virtualService.gateways.public (hasKey .Values.globals "istio") (hasKey .Values.globals.istio "gateways") (hasKey .Values.globals.istio.gateways "public") (ne .Values.globals.istio.gateways.public "") }}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ include "common.fullname" . }}-public
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  gateways:
    {{- include "common.virtualServiceGatewaysPublic" . | nindent 4 }}
  hosts:
    - {{ include "common.domain" . }}
    {{- if .Values.virtualService.allowWildcard }}
    - "*.{{ include "common.domain" . }}"
    {{- end }}
    - mesh
  http:
    - route:
        - destination:
            host: {{ include "common.fullname" . }}
            port:
              {{- if .Values.virtualService.servicePort }}
              number: {{ .Values.virtualService.servicePort }}
              {{- else }}
              number: {{ include "common.servicePort" . }}
              {{- end }}

{{- end }}
{{- if and .Values.virtualService.gateways.private (hasKey .Values.globals "istio") (hasKey .Values.globals.istio "gateways") (hasKey .Values.globals.istio.gateways "private") (ne .Values.globals.istio.gateways.private "") }}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ include "common.fullname" . }}-private
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  gateways:
    {{- include "common.virtualServiceGatewaysPrivate" . | nindent 4 }}
  hosts:
    - {{ include "common.domain" . }}
    {{- if .Values.virtualService.allowWildcard }}
    - "*.{{ include "common.domain" . }}"
    {{- end }}
    - mesh
  http:
    - route:
        - destination:
            host: {{ include "common.fullname" . }}
            port:
              {{- if .Values.virtualService.servicePort }}
              number: {{ .Values.virtualService.servicePort }}
              {{- else }}
              number: {{ include "common.servicePort" . }}
              {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
ServiceEntry for mesh-internal DNS resolution of public domains.
When pods resolve <subdomain>.olsen.cloud, the sidecar DNS proxy returns
a mesh-internal VIP so traffic stays in-cluster instead of hairpinning
through the public internet.
- HTTP: routes directly to the backend via the mesh VirtualService
- HTTPS: routes to the Istio gateway for TLS termination (requires
  DestinationRule to disable mTLS on the gateway since it has no sidecar)
*/}}
{{- define "common.serviceEntry" -}}
{{- if and .Values.virtualService.enabled .Values.subdomain (hasKey .Values.globals "domain") (ne .Values.globals.domain "") }}
---
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: {{ include "common.fullname" . }}-mesh
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  hosts:
    - {{ include "common.domain" . }}
  ports:
    - number: 80
      name: http
      protocol: HTTP
    - number: 443
      name: https
      protocol: HTTPS
  resolution: DNS
  location: MESH_INTERNAL
  endpoints:
    - address: gateway.istio-ingress.svc.cluster.local
      ports:
        https: 443
{{- end }}
{{- end }}

{{/*
Full DNS resource
*/}}
{{- define "common.dns" -}}
{{- if and .Values.dns .Values.dns.enabled (hasKey .Values.globals "networking") (hasKey .Values.globals.networking "private") (hasKey .Values.globals.networking.private "ip") (ne .Values.globals.networking.private.ip "") }}
---
apiVersion: dns.homelab.mortenolsen.pro/v1alpha1
kind: DNSRecord
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  type: {{ .Values.dns.type | default "A" }}
  domain: {{ .Values.globals.domain }}
  subdomain: {{ .Values.subdomain }}
  {{- if .Values.dns.dnsClassRef }}
  dnsClassRef:
    {{- toYaml .Values.dns.dnsClassRef | nindent 4 }}
  {{- end }}
  values:
    - {{ .Values.globals.networking.private.ip | quote }}
{{- end }}
{{- end }}

{{/*
Full OIDC/AuthentikClient resource
*/}}
{{- define "common.oidc" -}}
{{- if and .Values.oidc .Values.oidc.enabled (hasKey .Values.globals "authentik") (hasKey .Values.globals.authentik "ref") (hasKey .Values.globals.authentik.ref "name") (hasKey .Values.globals.authentik.ref "namespace") (ne .Values.globals.authentik.ref.name "") (ne .Values.globals.authentik.ref.namespace "") }}
---
apiVersion: authentik.homelab.mortenolsen.pro/v1alpha1
kind: AuthentikClient
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  serverRef:
    name: {{ .Values.globals.authentik.ref.name }}
    namespace: {{ .Values.globals.authentik.ref.namespace }}
  name: {{ include "common.fullname" . }}
  redirectUris:
    {{- range .Values.oidc.redirectUris }}
    - {{ printf "https://%s%s" (include "common.domain" $) . | quote }}
    {{- end }}
  subjectMode: {{ .Values.oidc.subjectMode | default "user_username" }}
{{- end }}
{{- end }}

{{/*
Full PostgreSQL Database resource
*/}}
{{- define "common.database" -}}
{{- if and .Values.database .Values.database.enabled (hasKey .Values.globals "database") (hasKey .Values.globals.database "ref") (hasKey .Values.globals.database.ref "name") (hasKey .Values.globals.database.ref "namespace") (ne .Values.globals.database.ref.name "") (ne .Values.globals.database.ref.namespace "") }}
---
apiVersion: postgres.homelab.mortenolsen.pro/v1
kind: PostgresDatabase
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  clusterRef:
    name: {{ .Values.globals.database.ref.name | quote }}
    namespace: {{ .Values.globals.database.ref.namespace | quote }}
{{- end }}
{{- end }}

{{/*
Password generators for External Secrets (create these first)
*/}}
{{- define "common.externalSecrets.passwordGenerators" -}}
{{- if .Values.externalSecrets }}
{{- range .Values.externalSecrets }}
{{- $secretName := .name | default (printf "%s-%s" $.Release.Name "secrets") }}
{{- $secretName = $secretName | replace "{release}" $.Release.Name | replace "{fullname}" (include "common.fullname" $) }}
{{- range .passwords }}
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: {{ $secretName }}-{{ .name }}-generator
  namespace: {{ $.Release.Namespace }}
  labels:
    {{- include "common.labels" $ | nindent 4 }}
spec:
  length: {{ .length | default 32 }}
  allowRepeat: {{ .allowRepeat | default false }}
  noUpper: {{ .noUpper | default false }}
  {{- if .encoding }}
  encoding: {{ .encoding }}
  {{- end }}
  {{- if .secretKeys }}
  secretKeys:
    {{- range .secretKeys }}
    - {{ . }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
External Secrets (create these after password generators)
*/}}
{{- define "common.externalSecrets.externalSecrets" -}}
{{- if .Values.externalSecrets }}
{{- range .Values.externalSecrets }}
{{- $secretName := .name | default (printf "%s-%s" $.Release.Name "secrets") }}
{{- $secretName = $secretName | replace "{release}" $.Release.Name | replace "{fullname}" (include "common.fullname" $) }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ $secretName }}
  namespace: {{ $.Release.Namespace }}
  labels:
    {{- include "common.labels" $ | nindent 4 }}
spec:
  refreshInterval: "0"
  # rotationPolicy is intentionally not set to ensure no automatic rotation
  target:
    name: {{ $secretName }}
    creationPolicy: Owner
  dataFrom:
    {{- range .passwords }}
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: {{ $secretName }}-{{ .name }}-generator
    {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Full External Secrets resources (ExternalSecret + Password generators)
Combined helper that outputs generators first, then ExternalSecrets
*/}}
{{- define "common.externalSecrets" -}}
{{- include "common.externalSecrets.passwordGenerators" . }}
{{- include "common.externalSecrets.externalSecrets" . }}
{{- end }}

{{/*
Blackbox Probe for HTTP service monitoring.
Automatically generated when .Values.service is defined, unless probe.enabled=false.
Supports optional probe.path to override the probed URL path (default: /).
*/}}
{{- define "common.probe" -}}
{{- $probeEnabled := true }}
{{- if and .Values.probe (hasKey .Values.probe "enabled") }}
{{- $probeEnabled = .Values.probe.enabled }}
{{- end }}
{{- if and .Values.service $probeEnabled }}
---
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    release: prometheus-operator
    {{- include "common.labels" . | nindent 4 }}
spec:
  interval: 60s
  scrapeTimeout: 10s
  module: http_2xx
  prober:
    url: blackbox-exporter.monitoring.svc.cluster.local:9115
    path: /probe
  targets:
    staticConfig:
      static:
        - http://{{ include "common.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local:{{ include "common.servicePort" . }}{{ if and .Values.probe .Values.probe.path }}{{ .Values.probe.path }}{{ end }}
      labels:
        probe_group: application
{{- end }}
{{- end }}

{{/*
Volsync ReplicationSource resources for PVCs with backup enabled.
Creates one ReplicationSource per PVC that has backup: true.
Mounts the NFS share directly into the restic mover pod via moverVolumes.
*/}}
{{- define "common.backup" -}}
{{- if and .Values.globals .Values.globals.backup .Values.globals.backup.enabled .Values.persistentVolumeClaims }}
{{- $globals := .Values.globals }}
{{- $backup := .Values.globals.backup }}
{{- range .Values.persistentVolumeClaims }}
{{- if .backup }}
{{- $backupName := printf "backup-%s-%s" $.Release.Name .name }}
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: {{ $backupName }}
  namespace: {{ $.Release.Namespace }}
spec:
  sourcePVC: {{ $.Release.Name }}-{{ .name }}
  trigger:
    schedule: {{ .backupSchedule | default (printf "%d 4 * * *" (mod (len $backupName) 60)) | quote }}
  restic:
    pruneIntervalDays: 7
    repository: volsync-restic
    copyMethod: Direct
    cacheCapacity: 1Gi
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
    moverVolumes:
      - mountPath: backup
        volumeSource:
          nfs:
            server: {{ $backup.nfs.server }}
            path: {{ $backup.nfs.path }}/{{ $.Release.Name }}-{{ .name }}
    retain:
      {{- if .backupRetain }}
      {{- toYaml .backupRetain | nindent 6 }}
      {{- else }}
      {{- toYaml $backup.retain | nindent 6 }}
      {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Full All-in-One resource
Includes all standard resources based on values.yaml configuration
*/}}
{{- define "common.all" -}}
{{- include "common.deployment" . }}
{{- include "common.serviceAccount" . }}
{{- include "common.service" . }}
{{- include "common.pvc" . }}
{{- include "common.virtualService" . }}
{{- include "common.serviceEntry" . }}
{{- include "common.dns" . }}
{{- include "common.oidc" . }}
{{- include "common.database" . }}
{{- include "common.externalSecrets" . }}
{{- include "common.probe" . }}
{{- include "common.backup" . }}
{{- end }}
