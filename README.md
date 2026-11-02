# Oficina360 - Infraestrutura AWS

Infraestrutura como código da Oficina360 para o laboratório da Fase 3.
---
# Tecnologias utilizadas
- Kubernets
- Terraform

---
## Arquitetura
````mermaid
flowchart LR
Client[Postman / Cliente] --> Kong[Kong API Gateway]

    Kong -->|/auth| APIGW[AWS API Gateway]
    APIGW --> Lambda[Lambda de autenticação]

    Kong -->|/api| API[API Oficina360]
    API --> RDS["(PostgreSQL no RDS)"]

    Lambda --> RDS
    Lambda -->|Gera JWT| Client
    Client -->|Bearer JWT| Kong

    subgraph EKS[Amazon EKS]
        Kong
        API
        Alloy[Grafana Alloy]
    end

    API -->|stdout| Alloy
    Kong -->|stdout| Alloy
    Alloy --> Loki[Grafana Loki]
    Grafana[Grafana] --> Loki
````

```text
Internet
   |
   v
Kong (LoadBalancer no EKS)
   |---------------------> API Spring Boot no EKS
   |                              |
   |                              v
   |                         RDS PostgreSQL
   |
   +---- /auth -----------> API Gateway/SAM -> Lambda Java

Alloy -> Loki -> Grafana
          todos no mesmo EKS, em namespaces separados
```

## Fluxo de autenticação
````mermaid
sequenceDiagram
    actor Cliente
    participant Kong
    participant APIGateway as AWS API Gateway
    participant Lambda
    participant RDS
    participant API as API Oficina360

    Cliente->>Kong: POST /auth/auth
    Kong->>APIGateway: POST /Prod/auth
    APIGateway->>Lambda: Executa autenticação
    Lambda->>Lambda: Valida CPF/documento
    Lambda->>RDS: Consulta cliente e status
    RDS-->>Lambda: Dados do cliente
    Lambda-->>Cliente: JWT

    Cliente->>Kong: GET /api/servicos/listar + JWT
    Kong->>API: GET /servicos/listar + JWT
    API->>API: Valida assinatura, issuer e expiração
    API->>RDS: Consulta serviços
    RDS-->>API: Resultado
    API-->>Cliente: HTTP 200
````
## Fluxo ci/cd

````mermaid
flowchart TD
    PR[Pull Request] --> Checks[Testes e validações]
    Checks --> Security[Análise de segurança]
    Security --> Main[Merge na branch main]

    Main --> Terraform[Terraform plan e apply]
    Main --> Build[Build da aplicação]
    Build --> Image[Imagem Docker]
    Image --> Registry[Docker Hub / Registry]
    Registry --> Deploy[Deploy no EKS]

    Terraform --> AWS[AWS]
    Deploy --> Rollout[Rollout Kubernetes]
    Rollout --> Validation[Validação de disponibilidade]
````
## Responsabilidades deste repositório

- Terraform: VPC, EKS, node group, RDS e Security Groups.
- Kubernetes/Helm: API, Kong, Loki, Alloy e Grafana.
- GitHub Actions: validate, deploy e destroy da plataforma.

A imagem da API é pública no Docker Hub. A Lambda possui repositório e pipeline próprios.

## Estrutura

```text
.github/workflows/       pipelines manuais
terraform/lab/           infraestrutura AWS
k8s/aws/                 API no EKS
k8s/kong/                gateway e rota da API
k8s/observabilidade/     values Helm
k8s/grafana/             dashboard provisionado
scripts/                 validação e diagnóstico
```

## Pré-requisitos no GitHub

Secrets:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
DB_USERNAME
DB_PASSWORD
JWT_SECRET
GRAFANA_ADMIN_PASSWORD
```

Repository Variable:

```text
AWS_REGION=us-east-1
```

## Validar localmente

```bash
bash scripts/validate-platform.sh
```

## Ordem de deploy

1. Execute `Infrastructure Apply`.
2. Execute `Aplicacao` com ação `deploy` e informe a imagem Docker Hub.
3. Implante a Lambda pelo repositório próprio.
4. Execute `Kong` com ação `deploy`.
5. Execute `Observabilidade` com ação `deploy`.

Os workflows são manuais. Escolher `deploy` e clicar em **Run workflow** já é a confirmação. Não existe segunda confirmação para deploy.

## Ordem de destruição

1. Destrua a stack SAM da Lambda no repositório próprio.
2. Execute `Observabilidade` com ação `destroy`.
3. Execute `Kong` com ação `destroy`.
4. Execute `Aplicacao` com ação `destroy`.
5. Execute `Infrastructure Destroy`.

A confirmação textual `DESTROY` deve existir apenas para a destruição total da infraestrutura.

## Diagnósticos

Cada workflow salva o diagnóstico em arquivo `.txt` e publica o arquivo como **Artifact** da execução no GitHub Actions.

Caminho no GitHub:

```text
Actions -> execução do workflow -> Artifacts
```

Os artifacts estão configurados com `retention-days: 3`, portanto são removidos automaticamente após três dias.

## Grafana

O datasource Loki e o dashboard `Oficina360 - Logs` são provisionados automaticamente. O dashboard inclui:

- logs do namespace `oficina360`;
- erros por minuto;
- volume de logs por minuto.

O endereço externo aparece em:

```bash
kubectl get svc grafana -n observability
```

Usuário padrão: `admin`. A senha vem do Secret `GRAFANA_ADMIN_PASSWORD`.
