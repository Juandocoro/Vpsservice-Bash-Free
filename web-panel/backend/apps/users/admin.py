from django.contrib import admin
from .models import User


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    """Configuración del admin para el modelo User"""
    
    list_display = ('username', 'expiration_date', 'connection_limit', 'date_created')
    list_filter = ('date_created', 'date_modified')
    search_fields = ('username',)
    readonly_fields = ('date_created', 'date_modified', 'password_hash')
    
    fieldsets = (
        ('Información Básica', {
            'fields': ('username', 'password_hash')
        }),
        ('Límites', {
            'fields': ('connection_limit', 'expiration_date')
        }),
        ('Metadata', {
            'fields': ('date_created', 'date_modified'),
            'classes': ('collapse',)
        }),
    )

    def get_readonly_fields(self, request, obj=None):
        """Solo lectura en ciertos campos"""
        if obj:  # Editar
            return self.readonly_fields + ('username',)
        return self.readonly_fields
