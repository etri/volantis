{{/*
volantis.nf — the ConfigMap and Deployment every network function shares.

Eight NFs differ only in their name, their extra pod labels, their config keys
and, for PRAN, one extra container port. Everything else — the volume wiring,
the two ports, the readiness probe, the POD_NAME/POD_NAMESPACE pair — is
identical, and having it in one place is what stops a new NF from quietly
missing one of them.

Takes a dict:

  root      $
  name      the resource name stem: `ausf`, `amf-10-100`, `smf-1-010203`.
            Renders <name>-config and <name>-dep.
  app       the binary, the config filename, the image suffix and the `app`
            label — all the same string by construction.
  labels    extra pod labels beyond app/plmnId: amfset, slice, tac
  replicas
  config    the NF-specific config keys. plmnId and mesh are added here, so no
            caller can forget either.
  ports     extra container ports beyond sbi and agent
*/}}
{{- define "volantis.nf" -}}
{{- $root := .root -}}
{{- $ns := $root.Values.namespace.name -}}

{{- $labels := deepCopy (default (dict) .labels) -}}
{{- $_ := set $labels "app" .app -}}
{{- $_ := set $labels "plmnId" (include "volantis.plmnId" $root) -}}

{{- $mesh := dict "registrar" $root.Values.registrar -}}
{{- if $root.Values.meshLabels -}}
{{- $_ := set $mesh "labels" $root.Values.meshLabels -}}
{{- end -}}

{{- $config := deepCopy (default (dict) .config) -}}
{{- $_ := set $config "plmnId" (dict "mcc" $root.Values.plmn.mcc "mnc" $root.Values.plmn.mnc) -}}
{{- $_ := set $config "mesh" $mesh -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}-config
  namespace: {{ $ns }}
data:
  {{ .app }}.json: |
{{ toPrettyJson $config | indent 4 }}

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}-dep
  namespace: {{ $ns }}
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
{{ toYaml $labels | indent 6 }}
  template:
    metadata:
      labels:
{{ toYaml $labels | indent 8 }}
    spec:
      volumes:
        - name: nf-config
          configMap:
            name: {{ .name }}-config
      containers:
        - name: {{ .app }}
          image: {{ include "volantis.image" (dict "root" $root "app" .app) }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          command: ["./{{ .app }}"]
          args: ["-c", "/etc/config/{{ .app }}.json"]
          volumeMounts:
            - mountPath: /etc/config
              name: nf-config
          ports:
            - name: sbi
              containerPort: {{ $root.Values.ports.sbi }}
            - name: agent
              containerPort: {{ $root.Values.ports.agent }}
{{- with .ports }}
{{ toYaml . | indent 12 }}
{{- end }}
          resources:
{{ toYaml $root.Values.resources | indent 12 }}
          # /ready on the agent port is the mesh's own answer to "is this
          # instance selectable": 503 with "active": false until the NF has
          # pulled its configuration from NSM and opened its SBI gate.
          readinessProbe:
            httpGet:
              path: /ready
              port: {{ $root.Values.ports.agent }}
            initialDelaySeconds: 5
            periodSeconds: 10
          env:
            # the gateway reads this pod through the API server to take its
            # labels; POD_NAME/POD_NAMESPACE are how it is told which pod
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
{{- end -}}
