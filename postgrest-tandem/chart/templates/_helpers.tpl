{{- define "postgrest-tandem.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 }}
{{- end }}
{{- end }}
