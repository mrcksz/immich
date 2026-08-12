<script lang="ts">
  import { Button, Modal, ModalBody, Text } from '@immich/ui';
  import { mdiDownload, mdiFileOutline, mdiImageOutline } from '@mdi/js';
  import { t } from 'svelte-i18n';

  type Props = {
    onClose: (target?: 'photos' | 'file') => void;
  };

  let { onClose }: Props = $props();
</script>

<Modal title={$t('download')} icon={mdiDownload} size="small" {onClose}>
  <ModalBody>
    <div class="flex flex-col gap-3">
      <Button size="large" leadingIcon={mdiImageOutline} onclick={() => onClose('photos')}>
        {$t('save_as_image')}
      </Button>
      <Text size="tiny" color="muted" class="-mt-2 px-1">{$t('save_as_image_description')}</Text>

      <Button
        size="large"
        variant="outline"
        color="secondary"
        leadingIcon={mdiFileOutline}
        onclick={() => onClose('file')}
      >
        {$t('save_as_file')}
      </Button>
      <Text size="tiny" color="muted" class="-mt-2 px-1">{$t('save_as_file_description')}</Text>
    </div>
  </ModalBody>
</Modal>
