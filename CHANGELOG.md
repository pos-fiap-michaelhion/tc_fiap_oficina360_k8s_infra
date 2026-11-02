# Changelog

Todas as alterações relevantes deste projeto serão documentadas neste arquivo.

O formato é baseado em Keep a Changelog e o projeto utiliza Versionamento Semântico.

## [Unreleased]

### Added

### Changed

### Fixed

### Security

## [1.0.0] - 2026-11-02

### Added

- Provisionamento da VPC e dos componentes de rede com Terraform.
- Provisionamento do cluster Amazon EKS e do node group.
- Provisionamento do PostgreSQL no Amazon RDS.
- Implantação da API Oficina360 no Kubernetes.
- Implantação do Kong Gateway com Helm.
- Roteamento público da API pelo prefixo `/api`.
- Integração da autenticação serverless pelo prefixo `/auth`.
- Publicação do Grafana pelo prefixo `/grafana`.
- Implantação do Grafana, Loki e Alloy.
- Coleta dos logs da API e do Kong.
- Provisionamento automático do datasource Loki.
- Dashboard Oficina360 para consulta dos logs.
- Pipelines de validação, deploy e destroy.
- Diagnósticos sanitizados publicados como artifacts.
- Proteção da branch principal contra commits diretos.
- Documentação da arquitetura e dos fluxos de autenticação,
  observabilidade e CI/CD.

### Changed

- Configuração do Kong para remover o prefixo `/api`.
- Configuração HTTPS para integração com o Amazon API Gateway.
- Configuração do Host do upstream externo.
- Configuração do Grafana para execução no subpath `/grafana/`.
- Renderização de `AUTH_API_HOST` antes do `kubectl apply`.

### Fixed

- Correção do roteamento entre Kong e API.
- Correção do roteamento entre Kong e Lambda.
- Correção da aceitação do JWT gerado pela Lambda.
- Correção da publicação do Grafana pelo Kong.
- Correção da coleta dos logs do Kong pelo Alloy.
- Correção dos diagramas Mermaid no README.

### Security

- Uso de GitHub Secrets para credenciais e valores sensíveis.
- Proteção da branch `main`.
- Restrição de mudanças por Pull Request.
- Remoção de JWT, CPF e credenciais dos logs.
- Sanitização dos arquivos de diagnóstico.

[Unreleased]: https://github.com/ORGANIZACAO/REPOSITORIO/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ORGANIZACAO/REPOSITORIO/releases/tag/v1.0.0
