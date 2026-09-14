# ---------------------------------------------------------------------------
# Salidas
#
# Se consultan cuando se quiera con "terraform output". Son especialmente utiles
# despues de reiniciar la sesion del laboratorio, porque las IP PUBLICAS cambian
# al detener y volver a encender las instancias. Las privadas no.
# ---------------------------------------------------------------------------

output "topologia" {
  description = "Como quedaron repartidas las plataformas entre servidores."
  value = {
    modo = var.topologia
    servidores = {
      for nombre, cfg in local.servidores :
      nombre => "${cfg.rol} [${cfg.perfiles}]  ip privada ${local.ips[nombre]}"
    }
  }
}

output "sitio_publico" {
  description = "Entrada publica de Andys Motors, a traves del balanceador."
  value       = "http://${aws_instance.servidor["borde"].public_ip}"
}

output "sitio_publico_dns" {
  description = <<-EOT
    El mismo sitio con un nombre DNS. sslip.io resuelve la IP contenida en el
    propio nombre, sin costo ni permisos, evitando crear una hosted zone.
  EOT
  value       = "http://${aws_instance.servidor["borde"].public_ip}.sslip.io"
}

output "estado_del_balanceador" {
  description = "Pagina de estado de HAProxy: muestra cada plataforma UP o DOWN."
  value       = "http://${aws_instance.servidor["borde"].public_ip}:8404/stats"
}

output "metricas_del_balanceador" {
  description = "Endpoint Prometheus de HAProxy (mas de 200 familias de metricas)."
  value       = "http://${aws_instance.servidor["borde"].public_ip}:8404/metrics"
}

output "ips_publicas" {
  description = "IP publica de cada servidor, para conectarse por SSH."
  value       = { for nombre, inst in aws_instance.servidor : nombre => inst.public_ip }
}

output "ips_privadas" {
  description = "IP privada de cada servidor. Son fijas: no cambian al reiniciar."
  value       = local.ips
}

output "endpoints_de_metricas" {
  description = <<-EOT
    Direcciones que hay que scrapear al construir el stack de monitoreo. Son el
    punto de partida del prometheus.yml.
  EOT
  value = merge(
    {
      for plataforma, puerto in local.puertos :
      plataforma => "${local.host_de[plataforma]}:${puerto}/metrics"
    },
    { haproxy = "${local.ips["borde"]}:8404/metrics" }
  )
}

output "grafana" {
  description = "Grafana de referencia (usuario admin). Solo existe si enable_monitoring = true."
  value       = var.enable_monitoring ? "http://${aws_instance.monitoreo[0].public_ip}:3000" : "monitoreo de referencia deshabilitado: el stack lo construye el estudiante"
}

output "prometheus" {
  description = "Prometheus de referencia. La pestania /targets debe mostrar las plataformas en verde."
  value       = var.enable_monitoring ? "http://${aws_instance.monitoreo[0].public_ip}:9090/targets" : "monitoreo de referencia deshabilitado"
}

output "bucket_documentos" {
  description = "Bucket S3 con los documentos del negocio y el paquete del entorno."
  value       = aws_s3_bucket.documentos.bucket
}

output "rds_endpoint" {
  description = "Endpoint de RDS cuando enable_rds = true."
  value       = var.enable_rds ? aws_db_instance.main[0].address : "RDS deshabilitado: la base de datos corre como contenedor en ServerData"
}

output "siguientes_pasos" {
  description = "Que hacer despues del apply."
  value       = <<-EOT

    1. El arranque de cada servidor toma entre 3 y 6 minutos: instala Docker,
       descarga el entorno desde S3 y construye la imagen de las aplicaciones.
       Que la instancia diga "running" no significa que ya este lista.

    2. Revisar el avance en cualquier servidor:
         ssh -i labsuser.pem ec2-user@<IP_PUBLICA>
         sudo tail -f /var/log/cloud-init-output.log
         cd /opt/andys && sudo docker compose ps

    3. Comprobar que la plataforma responde:
         curl http://${aws_instance.servidor["borde"].public_ip}/
         curl http://${aws_instance.servidor["borde"].public_ip}/stock/api/stock

    4. Ver el estado de cada plataforma desde el balanceador:
         http://${aws_instance.servidor["borde"].public_ip}:8404/stats

    5. Generar trafico con la curva horaria del negocio:
         cd ../demo
         ./scripts/generar_trafico.py --url http://${aws_instance.servidor["borde"].public_ip} \
            --hora-inicio 9 --duracion 1200

    6. Al terminar la clase, SIEMPRE liberar los recursos:
         terraform destroy
  EOT
}
