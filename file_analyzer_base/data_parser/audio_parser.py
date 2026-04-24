import os
from typing import List, Optional
from io import BytesIO
from .base_parser import BaseParser, DataBlock, ModalityType


class AudioParser(BaseParser):
    def __init__(self, use_transcription: bool = True, model_size: str = 'base'):
        super().__init__()
        self.supported_extensions = ['wav', 'mp3', 'm4a', 'flac', 'ogg', 'aac']
        self.use_transcription = use_transcription
        self.model_size = model_size
        self._whisper_model = None

    def parse(self, file_path: str) -> List[DataBlock]:
        if not self.can_parse(file_path):
            raise ValueError(f"Unsupported file format: {file_path}")
        
        blocks = []
        
        with open(file_path, 'rb') as f:
            audio_bytes = f.read()
        
        audio_info = self._get_audio_info(file_path, audio_bytes)
        
        basic_block = DataBlock(
            block_id=self._generate_block_id(file_path, 0),
            modality=ModalityType.AUDIO,
            content=audio_bytes,
            text_content=f"[Audio file: {os.path.basename(file_path)}]",
            file_path=file_path,
            metadata={
                'source': 'audio_parser',
                'file_size': len(audio_bytes),
                **audio_info
            }
        )
        blocks.append(basic_block)
        
        if self.use_transcription:
            transcription = self._transcribe(file_path)
            if transcription:
                transcript_block = DataBlock(
                    block_id=self._generate_block_id(file_path, 1),
                    modality=ModalityType.TEXT,
                    content=transcription,
                    text_content=transcription,
                    file_path=file_path,
                    metadata={
                        'source': 'transcription',
                        'model': 'whisper',
                        'model_size': self.model_size
                    }
                )
                blocks.append(transcript_block)
        
        return blocks

    def _get_audio_info(self, file_path: str, audio_bytes: bytes) -> dict:
        info = {}
        
        try:
            from pydub import AudioSegment
            audio = AudioSegment.from_file(BytesIO(audio_bytes))
            info.update({
                'duration_seconds': len(audio) / 1000.0,
                'channels': audio.channels,
                'sample_width': audio.sample_width,
                'frame_rate': audio.frame_rate
            })
        except ImportError:
            try:
                import wave
                with wave.open(BytesIO(audio_bytes), 'rb') as wf:
                    info.update({
                        'channels': wf.getnchannels(),
                        'sample_width': wf.getsampwidth(),
                        'frame_rate': wf.getframerate(),
                        'n_frames': wf.getnframes(),
                        'duration_seconds': wf.getnframes() / wf.getframerate()
                    })
            except Exception:
                pass
        
        return info

    def _transcribe(self, file_path: str) -> Optional[str]:
        if self._whisper_model is None:
            self._whisper_model = self._load_whisper()
        
        if self._whisper_model is None:
            return None
        
        try:
            result = self._whisper_model.transcribe(file_path)
            return result.get('text', '')
        except Exception as e:
            print(f"Transcription failed: {str(e)}")
            return None

    def _load_whisper(self):
        try:
            import whisper
            return whisper.load_model(self.model_size)
        except ImportError:
            print(
                "whisper is required for audio transcription. "
                "Install with: pip install openai-whisper"
            )
            return None
