{{/*
Expand the name of the chart.
*/}}
{{- define "risk-engine.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "risk-engine.fullname" -}}
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
{{- define "risk-engine.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "risk-engine.labels" -}}
helm.sh/chart: {{ include "risk-engine.chart" . }}
{{ include "risk-engine.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mini-nasdaq-gitops
{{- end }}

{{/*
Selector labels
*/}}
{{- define "risk-engine.selectorLabels" -}}
app.kubernetes.io/name: {{ include "risk-engine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ include "risk-engine.name" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "risk-engine.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "risk-engine.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
