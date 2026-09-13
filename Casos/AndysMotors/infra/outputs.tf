# ---------------------------------------------------------------------------
# Salidas
#
# Se consultan en cualquier momento con "terraform output". Son especialmente
# utiles despues de reiniciar la sesion del lab, porque las IP PUBLICAS cambian
# al detener y volver a encender las instancias.
# ---------------------------------------------------------------------------

output "app_ip_publica" {
  description = "IP publica de la instancia de aplicacion."
  value       = aws_instance.app.public_ip
}

output "app_ip_privada" {
  description = "IP privada de la instancia de aplicacion (se conserva entre reinicios)."
  value       = aws_instance.app.private_ip
}

output "sitio_web" {
  description = "URL del sitio web publico de Andys Motors."
  value       = "http://${aws_instance.app.public_ip}"
}

output "sitio_web_dns" {
  description = <<-EOT
    Mismo sitio, con un nombre DNS. sslip.io es un resolvedor publico y gratuito
    que devuelve la IP contenida en el propio nombre: evita tener que crear una
    hosted zone en Route 53, que cuesta y no siempre esta habilitada en el lab.
  EOT
  value       = "http://${aws_instance.app.public_ip}.sslip.io"
}

output "ssh_app" {
  description = "Comando para conectarse por SSH a la instancia de aplicacion."
  value       = "ssh -i labsuser.pem ec2-user@${aws_instance.app.public_ip}"
}

output "grafana" {
  description = "URL de Grafana (usuario: admin)."
  value       = var.enable_monitoring ? "http://${aws_instance.monitoring[0].public_ip}:3000" : "monitoreo deshabilitado (enable_monitoring = false)"
}

output "prometheus" {
  description = "URL de Prometheus. La pestania /targets debe mostrar los jobs node, nginx y postgres en verde."
  value       = var.enable_monitoring ? "http://${aws_instance.monitoring[0].public_ip}:9090/targets" : "monitoreo deshabilitado (enable_monitoring = false)"
}

output "ssh_monitoring" {
  description = "Comando para conectarse por SSH a la instancia de monitoreo."
  value       = var.enable_monitoring ? "ssh -i labsuser.pem ec2-user@${aws_instance.monitoring[0].public_ip}" : "monitoreo deshabilitado"
}

output "bucket_documentos" {
  description = "Nombre del bucket S3 de documentos, imagenes y respaldos."
  value       = aws_s3_bucket.documentos.bucket
}

output "rds_endpoint" {
  description = "Endpoint de la base de datos RDS, cuando enable_rds = true."
  value       = var.enable_rds ? aws_db_instance.main[0].address : "RDS deshabilitado: la base de datos corre como contenedor en la instancia de aplicacion"
}

output "siguientes_pasos" {
  description = "Que revisar despues del apply."
  value       = <<-EOT

    1. El user_data tarda entre 2 y 4 minutos en terminar despues de que la
       instancia aparece como "running". Si el sitio no responde todavia, esperar.

    2. Revisar el avance del arranque:
         ssh -i labsuser.pem ec2-user@${aws_instance.app.public_ip}
         sudo tail -f /var/log/cloud-init-output.log

    3. Verificar los contenedores de la aplicacion:
         cd /opt/andys && sudo docker compose ps

    4. Verificar que los tres exporters responden:
         curl -s localhost:9100/metrics | head   # sistema operativo
         curl -s localhost:9113/metrics | head   # nginx
         curl -s localhost:9187/metrics | head   # postgresql

    5. Al terminar la clase, SIEMPRE liberar los recursos:
         terraform destroy
  EOT
}
