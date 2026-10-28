removed {
  from = terraform_data.code_security_configuration

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.code_security_configuration_settings

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.custom_pattern

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.custom_pattern_content

  lifecycle {
    destroy = false
  }
}
