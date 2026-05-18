{{/*
Expand the name of the chart.
*/}}
{{- define "order-execution-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "order-execution-api.fullname" -}}
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
{{- define "order-execution-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "order-execution-api.labels" -}}
helm.sh/chart: {{ include "order-execution-api.chart" . }}
{{ include "order-execution-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mini-nasdaq-gitops
{{- end }}

{{/*
Selector labels
*/}}
{{- define "order-execution-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "order-execution-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ include "order-execution-api.name" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "order-execution-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "order-execution-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
