{{/* Image reference for a component, e.g. "amf" -> registry/prefix+amf:tag */}}
{{- define "volantis.image" -}}
{{- printf "%s/%s%s:%s" .root.Values.image.registry .root.Values.image.prefix .name (.root.Values.image.tag | toString) -}}
{{- end -}}

{{/* PLMN as used in labels and service names, e.g. 001-01 */}}
{{- define "volantis.plmn" -}}
{{- printf "%s-%s" .Values.plmn.mcc .Values.plmn.mnc -}}
{{- end -}}

{{/* Multus attachment annotation for a static address on the lan network */}}
{{- define "volantis.multus" -}}
k8s.v1.cni.cncf.io/networks: |
  [
    {
      "name": "{{ .root.Values.multus.nad.name }}",
      "interface": "ext",
      "ips":["{{ .ip }}/{{ .root.Values.multus.nad.prefixLen }}"],
      "gateway": ["{{ .root.Values.multus.nad.gateway }}"]
    }
  ]
{{- end -}}

{{/* Downward-API environment shared by every network function */}}
{{- define "volantis.podEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
{{- end -}}

{{/* Container ports shared by every network function */}}
{{- define "volantis.nfPorts" -}}
- containerPort: {{ .Values.ports.sbi }}
- containerPort: {{ .Values.ports.state }}
{{- end -}}

{{/* Annotations telling the autoscaler where to read capacity state */}}
{{- define "volantis.stateAnnotations" -}}
autoscaling.volantis/state-port: "{{ .Values.ports.state }}"
autoscaling.volantis/state-path: "/state"
{{- end -}}

{{/* A headless service definition. Args: root, name, selector (map) */}}
{{- define "volantis.serviceDefinition" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    type: network-function
spec:
  clusterIP: None
  selector:
{{ toYaml .selector | indent 4 }}
  ports:
    - protocol: TCP
      port: {{ .root.Values.ports.sbi }}
{{- end -}}
